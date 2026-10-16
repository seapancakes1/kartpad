// GLES 3.0 renderer of the Mii editor's 3D preview (kartpad::mii::PreviewScene): a port of
// apple/shared/KartPadMiiPreview.inc.mm's Metal shader, draw setup, framing and idle animation.
// Created, used and destroyed on MiiPreviewView's GL thread only, with its context current.
#include <GLES3/gl3.h>
#include <android/log.h>
#include <jni.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <memory>
#include <numbers>
#include <random>
#include <vector>

#include "kartpad/mii/scene.h"

namespace {

using kartpad::mii::Image;
using kartpad::mii::Mesh;
using kartpad::mii::PreviewScene;

#ifndef KARTPAD_MII_GLSL_VERSION
#define KARTPAD_MII_GLSL_VERSION "#version 300 es\n"
#endif

constexpr char kVertexShader[] = KARTPAD_MII_GLSL_VERSION R"GLSL(
layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec4 color;
uniform mat4 mvp;
uniform mat4 model;
out vec3 vNormal;
out vec2 vUv;
out vec4 vColor;
void main() {
    gl_Position = mvp * vec4(position, 1.0);
    vNormal = (model * vec4(normal, 0.0)).xyz;
    vUv = uv;
    vColor = color;
}
)GLSL";

constexpr char kFragmentShader[] = KARTPAD_MII_GLSL_VERSION R"GLSL(
precision highp float;
in vec3 vNormal;
in vec2 vUv;
in vec4 vColor;
uniform vec4 tint;
uniform float textured, unlit, bodyMaterial, alphaThreshold;
uniform sampler2D diffuseMap, lightMap, highlightMap;
out vec4 fragment;
void main() {
    vec3 n = normalize(vNormal);
    if (bodyMaterial > 0.5) {
        // NW4R MiiBody TEV: vertex alpha is a lighting coefficient; texture alpha masks highlights.
        // Neither is surface transparency; the material's alpha test drops the atlas's transparent texels.
        vec2 env = vec2(n.x, -n.y) * 0.5 + 0.5;
        vec4 diffuse = texture(diffuseMap, vUv);
        if (diffuse.a < alphaThreshold) discard;
        vec3 lighting = clamp(vColor.rgb + texture(lightMap, env).rgb * vColor.a, 0.0, 1.0);
        vec3 rgb = clamp(diffuse.rgb * lighting, 0.0, 1.0) * tint.rgb;
        rgb = clamp(rgb + texture(highlightMap, env).rgb * diffuse.a, 0.0, 1.0);
        fragment = vec4(rgb, 1.0);
        return;
    }
    vec4 c = tint * vColor;
    // Textures are premultiplied so filtering has no dark fringes; undo it after sampling.
    if (textured > 0.5) { vec4 s = texture(diffuseMap, vUv); s.rgb /= max(s.a, 0.0001); c *= s; }
    if (c.a < 0.006) discard;
    float light = (unlit > 0.5 || length(vNormal) < 0.001) ? 1.0
        : 0.72 + 0.28 * max(0.0, dot(n, normalize(vec3(-0.3, 0.5, 0.8))));
    fragment = vec4(c.rgb * light, c.a);
}
)GLSL";

// Column-major 4x4, as GL takes it.
struct Matrix {
  std::array<float, 16> m{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
  float& At(int row, int column) { return m[column * 4 + row]; }
};

Matrix operator*(const Matrix& a, const Matrix& b) {
  Matrix c;
  for (int column = 0; column < 4; column++)
    for (int row = 0; row < 4; row++) {
      float sum = 0;
      for (int k = 0; k < 4; k++) sum += a.m[k * 4 + row] * b.m[column * 4 + k];
      c.m[column * 4 + row] = sum;
    }
  return c;
}

// KPMiiMatrix: a row-major 3x4 joint transform.
Matrix FromRows(const std::array<float, 12>& rows) {
  Matrix out;
  for (int row = 0; row < 3; row++)
    for (int column = 0; column < 4; column++) out.At(row, column) = rows[row * 4 + column];
  return out;
}

// KPMiiRotation: yaw about Y, then pitch about X, then roll about Z.
Matrix Rotation(float yaw, float pitch, float roll) {
  const float cy = std::cos(yaw), sy = std::sin(yaw), cp = std::cos(pitch), sp = std::sin(pitch),
              cr = std::cos(roll), sr = std::sin(roll);
  Matrix y, p, r;
  y.m[0] = cy; y.m[2] = -sy; y.m[8] = sy; y.m[10] = cy;
  p.m[5] = cp; p.m[6] = sp; p.m[9] = -sp; p.m[10] = cp;
  r.m[0] = cr; r.m[1] = sr; r.m[4] = -sr; r.m[5] = cr;
  return y * p * r;
}

double Now() {
  return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

GLuint Compile(GLenum type, const char* source) {
  GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);
  GLint ok = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[1024] = {};
    glGetShaderInfoLog(shader, sizeof log, nullptr, log);
    __android_log_print(ANDROID_LOG_WARN, "KartPadMiiPreview", "Shader: %s", log);
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

class Renderer {
 public:
  float yaw = 0;
  bool fullBody = false, reduceMotion = false, visible = true;
  std::array<float, 4> clear{.925f, .947f, .945f, 1};

  Renderer() : start_(Now()), nextBlink_(start_ + 2) { random_.seed(std::random_device{}()); }
  Renderer(const Renderer&) = delete;
  Renderer& operator=(const Renderer&) = delete;
  ~Renderer() {
    Release();
    if (program_) glDeleteProgram(program_);
    if (vao_) glDeleteVertexArrays(1, &vao_);
    for (GLuint sampler : samplers_)
      if (sampler) glDeleteSamplers(1, &sampler);
  }

  bool Create() {
    GLuint vertex = Compile(GL_VERTEX_SHADER, kVertexShader), fragment = Compile(GL_FRAGMENT_SHADER, kFragmentShader);
    if (vertex && fragment) {
      program_ = glCreateProgram();
      glAttachShader(program_, vertex);
      glAttachShader(program_, fragment);
      glLinkProgram(program_);
      GLint ok = 0;
      glGetProgramiv(program_, GL_LINK_STATUS, &ok);
      if (!ok) {
        char log[1024] = {};
        glGetProgramInfoLog(program_, sizeof log, nullptr, log);
        __android_log_print(ANDROID_LOG_WARN, "KartPadMiiPreview", "Program: %s", log);
        glDeleteProgram(program_);
        program_ = 0;
      }
    }
    if (vertex) glDeleteShader(vertex);
    if (fragment) glDeleteShader(fragment);
    if (!program_) return false;
    mvp_ = glGetUniformLocation(program_, "mvp");
    model_ = glGetUniformLocation(program_, "model");
    tint_ = glGetUniformLocation(program_, "tint");
    textured_ = glGetUniformLocation(program_, "textured");
    unlit_ = glGetUniformLocation(program_, "unlit");
    bodyMaterial_ = glGetUniformLocation(program_, "bodyMaterial");
    alphaThreshold_ = glGetUniformLocation(program_, "alphaThreshold");
    glUseProgram(program_);
    glUniform1i(glGetUniformLocation(program_, "diffuseMap"), 0);
    glUniform1i(glGetUniformLocation(program_, "lightMap"), 1);
    glUniform1i(glGetUniformLocation(program_, "highlightMap"), 2);
    glGenVertexArrays(1, &vao_);
    // GX clamp, repeat and mirrored repeat, indexed wrapS + wrapT * 3 as the Metal samplers.
    const GLint modes[] = {GL_CLAMP_TO_EDGE, GL_REPEAT, GL_MIRRORED_REPEAT};
    glGenSamplers(GLsizei(samplers_.size()), samplers_.data());
    for (unsigned t = 0; t < 3; t++)
      for (unsigned s = 0; s < 3; s++) {
        GLuint sampler = samplers_[s + t * 3];
        glSamplerParameteri(sampler, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glSamplerParameteri(sampler, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glSamplerParameteri(sampler, GL_TEXTURE_WRAP_S, modes[s]);
        glSamplerParameteri(sampler, GL_TEXTURE_WRAP_T, modes[t]);
      }
    return glGetError() == GL_NO_ERROR;
  }

  // GPU copies of the scene: interleaved vertices per part, premultiplied head textures, and for an
  // animated body three position/normal buffers per body part, re-posed in turn each frame.
  void Install(std::unique_ptr<PreviewScene> scene) {
    Release();
    scene_ = std::move(scene);
    if (!scene_) return;
    parts_.resize(scene_->parts.size());
    for (size_t i = 0; i < scene_->parts.size(); i++) {
      const auto& part = scene_->parts[i];
      std::vector<float> vertices;
      vertices.reserve(part.mesh.triangles.size() * 12);
      for (const auto& v : part.mesh.triangles)
        vertices.insert(vertices.end(), {v.x, v.y, v.z, v.nx, v.ny, v.nz, v.u, v.v, v.red, v.green, v.blue, v.alpha});
      glGenBuffers(1, &parts_[i].vertices);
      glBindBuffer(GL_ARRAY_BUFFER, parts_[i].vertices);
      glBufferData(GL_ARRAY_BUFFER, GLsizeiptr(vertices.size() * sizeof(float)), vertices.data(), GL_STATIC_DRAW);
      parts_[i].texture = Upload(part.texture, !part.bodyPart);
      parts_[i].lightMap = Upload(part.lightMap, false);
      parts_[i].highlightMap = Upload(part.highlightMap, false);
    }
    if (scene_->maskPart < scene_->parts.size()) {
      blink_ = Upload(scene_->blinkMask, true);
      smile_ = Upload(scene_->smileMask, true);
    }
    if (scene_->Animated())
      for (size_t i : scene_->rig.parts) {
        if (i >= parts_.size()) continue;
        std::vector<float> posed;
        for (const auto& v : scene_->parts[i].mesh.triangles) posed.insert(posed.end(), {v.x, v.y, v.z, v.nx, v.ny, v.nz});
        glGenBuffers(3, parts_[i].ring.data());
        for (GLuint buffer : parts_[i].ring) {
          glBindBuffer(GL_ARRAY_BUFFER, buffer);
          glBufferData(GL_ARRAY_BUFFER, GLsizeiptr(posed.size() * sizeof(float)), posed.data(), GL_DYNAMIC_DRAW);
        }
      }
    glBindBuffer(GL_ARRAY_BUFFER, 0);
  }

  bool HasScene() const { return scene_ != nullptr; }

  void SetAnimated(bool value) {
    animated_ = value;
    if (!value) smileUntil_ = blinkUntil_ = frontStart_ = 0;
  }
  void React() {
    if (animated_) smileUntil_ = Now() + 1.0;
  }
  void NoteInteraction() {
    interactionAt_ = Now();
    frontStart_ = 0;
  }
  // Ease the turntable back to the front; Reduce Motion (or an unseen preview) snaps instead.
  void EaseToFront() {
    if (!animated_) return;
    const float turned = std::remainder(yaw, float(2 * std::numbers::pi));
    if (std::abs(turned) < .01f) { yaw = 0; return; }
    if (reduceMotion || !visible) { yaw = 0; return; }
    frontFrom_ = turned;
    frontStart_ = Now();
  }

  void Draw(int width, int height) {
    glViewport(0, 0, width, height);
    glDepthMask(GL_TRUE);
    glClearColor(clear[0], clear[1], clear[2], clear[3]);
    glClearDepthf(1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    if (!program_ || width <= 0 || height <= 0) return;
    const float aspect = std::max(.1f, float(width) / float(height));
    // Animation state for this frame. Reduce Motion keeps blink and smile but drops body, sway and turns.
    const double now = Now();
    const bool animate = animated_ && scene_, move = animate && !reduceMotion;
    if (frontStart_ > 0) {
      const float t = float(std::min(1., (now - frontStart_) / .45)), ease = 1 - (1 - t) * (1 - t) * (1 - t);
      yaw = frontFrom_ * (1 - ease);
      if (t >= 1) { yaw = 0; frontStart_ = 0; }
    }
    if (animate && now >= nextBlink_) {
      std::uniform_real_distribution<double> wait(2.4, 6.0), chance(0, 1);
      blinkUntil_ = now + .11;
      nextBlink_ = chance(random_) < .15 ? now + .3 : now + wait(random_);
    }
    const GLuint face = animate && now < smileUntil_ ? smile_ : animate && now < blinkUntil_ ? blink_ : 0;
    std::array<float, 12> neck{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0};
    const bool posed = move && fullBody && scene_ && scene_->Animated() &&
                       std::any_of(parts_.begin(), parts_.end(), [](const Part& p) { return p.ring[0] != 0; });
    const unsigned slot = ringIndex_ % 3;
    if (posed) {
      std::vector<Mesh> bodies;
      neck = scene_->Pose(float((now - start_) * 60), bodies);  // one CHR0 frame per 60 Hz tick (NW4R default rate)
      std::vector<float> posedVertices;
      for (size_t k = 0; k < scene_->rig.parts.size() && k < bodies.size(); k++) {
        const size_t i = scene_->rig.parts[k];
        if (i >= parts_.size() || !parts_[i].ring[0]) continue;
        const size_t n = std::min(bodies[k].triangles.size(), scene_->parts[i].mesh.triangles.size());
        posedVertices.clear();
        for (size_t v = 0; v < n; v++) {
          const auto& q = bodies[k].triangles[v];
          posedVertices.insert(posedVertices.end(), {q.x, q.y, q.z, q.nx, q.ny, q.nz});
        }
        glBindBuffer(GL_ARRAY_BUFFER, parts_[i].ring[slot]);
        glBufferSubData(GL_ARRAY_BUFFER, 0, GLsizeiptr(posedVertices.size() * sizeof(float)), posedVertices.data());
      }
    }
    // Head sway: a slow drift of a few degrees, fading out while the Mii is being turned by hand.
    float sway = 0;
    if (move) {
      sway = float(std::clamp((now - interactionAt_ - 1.5) / 1.5, 0., 1.));
      sway = sway * sway * (3 - 2 * sway);
    }
    const double t = now - start_, tau = 2 * std::numbers::pi;
    const Matrix head = FromRows(neck) * Rotation(sway * float(.105 * std::sin(t * tau / 7.3) + .035 * std::sin(t * tau / 3.1)),
                                                  sway * float(.035 * std::sin(t * tau / 5.2)),
                                                  sway * float(.026 * std::sin(t * tau / 6.1)));
    // Framing: the full body or the head, wide enough for the turned Mii at this aspect.
    float center = 42, half = 47;
    if (scene_) {
      center = fullBody ? (scene_->top + scene_->bottom) / 2 : (scene_->headTop + scene_->headBottom) / 2;
      half = fullBody ? (scene_->top - scene_->bottom) * .57f : (scene_->headTop - scene_->headBottom) * .56f;
    }
    const float cs = std::cos(yaw), sn = std::sin(yaw);
    float horizontal = 0;
    if (scene_)
      for (const auto& part : scene_->parts)
        if (fullBody || !part.bodyPart)
          for (const auto& v : part.mesh.triangles) horizontal = std::max(horizontal, std::abs(cs * v.x + sn * v.z));
    half = std::max(half, std::max(30.f, horizontal * 1.08f) / aspect);
    Matrix model;
    model.m[0] = cs; model.m[2] = -sn; model.m[8] = sn; model.m[10] = cs;
    // Metal's depth -z/300+.5 over [0,1] is GL's -z/150 over [-1,1]: the same depth values.
    Matrix projection;
    projection.At(0, 0) = 1 / (half * aspect);
    projection.At(1, 1) = 1 / half;
    projection.At(2, 2) = -1 / 150.f;
    projection.At(1, 3) = -center / half;

    glUseProgram(program_);
    glBindVertexArray(vao_);
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LEQUAL);
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    // Metal's clockwise front faces with back culling; mirrored parts were rewound when built.
    glFrontFace(GL_CW);
    glCullFace(GL_BACK);
    for (GLuint index = 0; index < 4; index++) glEnableVertexAttribArray(index);
    for (size_t i = 0; scene_ && i < scene_->parts.size(); i++) {
      const auto& part = scene_->parts[i];
      if (part.bodyPart && !fullBody) continue;
      const Matrix world = part.bodyPart ? model : model * head, mvp = projection * world;
      glUniformMatrix4fv(mvp_, 1, GL_FALSE, mvp.m.data());
      glUniformMatrix4fv(model_, 1, GL_FALSE, world.m.data());
      glUniform4f(tint_, part.color[0] / 255.f, part.color[1] / 255.f, part.color[2] / 255.f, 1);
      glUniform1f(textured_, part.texture.width ? 1 : 0);
      glUniform1f(unlit_, part.unlit ? 1 : 0);
      glUniform1f(bodyMaterial_, part.bodyPart ? 1 : 0);
      glUniform1f(alphaThreshold_, part.alphaThreshold);
      if (part.doubleSided) glDisable(GL_CULL_FACE);
      else glEnable(GL_CULL_FACE);
      // Transparent overlays (face mask, nose line, glasses) don't write depth.
      glDepthMask(part.translucent ? GL_FALSE : GL_TRUE);
      const GLuint sampler = samplers_[std::min(part.texture.wrapS, 2u) + std::min(part.texture.wrapT, 2u) * 3];
      for (GLuint unit = 0; unit < 3; unit++) glBindSampler(unit, sampler);
      glActiveTexture(GL_TEXTURE0);
      glBindTexture(GL_TEXTURE_2D, part.texture.width ? (i == scene_->maskPart && face ? face : parts_[i].texture) : 0);
      if (part.bodyPart) {
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, parts_[i].lightMap);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, parts_[i].highlightMap);
      }
      constexpr GLsizei stride = 12 * sizeof(float);
      auto offset = [](size_t floats) { return reinterpret_cast<const void*>(floats * sizeof(float)); };
      if (posed && parts_[i].ring[0]) {
        glBindBuffer(GL_ARRAY_BUFFER, parts_[i].ring[slot]);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), offset(0));
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), offset(3));
      } else {
        glBindBuffer(GL_ARRAY_BUFFER, parts_[i].vertices);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, stride, offset(0));
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, stride, offset(3));
      }
      glBindBuffer(GL_ARRAY_BUFFER, parts_[i].vertices);
      glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, stride, offset(6));
      glVertexAttribPointer(3, 4, GL_FLOAT, GL_FALSE, stride, offset(8));
      glDrawArrays(GL_TRIANGLES, 0, GLsizei(part.mesh.triangles.size()));
    }
    glDepthMask(GL_TRUE);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindVertexArray(0);
    ringIndex_++;
  }

 private:
  struct Part {
    GLuint vertices = 0, texture = 0, lightMap = 0, highlightMap = 0;
    std::array<GLuint, 3> ring{};
  };
  struct Uploaded {
    const Image* source;
    bool premultiplied;
    GLuint texture;
  };

  // Body parts carry copies of the same atlas and maps: upload each distinct image once.
  GLuint Upload(const Image& image, bool premultiply) {
    if (!image.width || !image.height) return 0;
    for (const auto& known : uploaded_)
      if (known.premultiplied == premultiply && known.source->width == image.width &&
          known.source->height == image.height && known.source->rgba == image.rgba)
        return known.texture;
    std::vector<uint8_t> pixels = image.rgba;
    if (premultiply)
      for (size_t i = 0; i + 3 < pixels.size(); i += 4)
        for (unsigned c = 0; c < 3; c++) pixels[i + c] = uint8_t(unsigned(pixels[i + c]) * pixels[i + 3] / 255);
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, GLsizei(image.width), GLsizei(image.height), 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, pixels.data());
    uploaded_.push_back({&image, premultiply, texture});
    return texture;
  }

  void Release() {
    for (auto& part : parts_) {
      if (part.vertices) glDeleteBuffers(1, &part.vertices);
      if (part.ring[0]) glDeleteBuffers(3, part.ring.data());
    }
    for (const auto& known : uploaded_) glDeleteTextures(1, &known.texture);
    parts_.clear();
    uploaded_.clear();
    blink_ = smile_ = 0;
    scene_.reset();
  }

  GLuint program_ = 0, vao_ = 0;
  std::array<GLuint, 9> samplers_{};
  GLint mvp_ = -1, model_ = -1, tint_ = -1, textured_ = -1, unlit_ = -1, bodyMaterial_ = -1, alphaThreshold_ = -1;
  std::unique_ptr<PreviewScene> scene_;
  std::vector<Part> parts_;
  std::vector<Uploaded> uploaded_;
  GLuint blink_ = 0, smile_ = 0;
  unsigned ringIndex_ = 0;
  bool animated_ = false;
  double start_, nextBlink_, blinkUntil_ = 0, smileUntil_ = 0, interactionAt_ = 0, frontStart_ = 0;
  float frontFrom_ = 0;
  std::mt19937 random_;
};

Renderer* From(jlong handle) { return reinterpret_cast<Renderer*>(handle); }

}  // namespace

// 0 when the shader doesn't build: the view then shows a static portrait.
extern "C" JNIEXPORT jlong JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewCreate(JNIEnv*, jobject) {
  try {
    auto renderer = std::make_unique<Renderer>();
    return renderer->Create() ? reinterpret_cast<jlong>(renderer.release()) : 0;
  } catch (...) {
    return 0;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewDestroy(JNIEnv*, jobject, jlong renderer) {
  delete From(renderer);
}

// Takes ownership of a scene from nativeBuildScene (0 clears the preview).
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewSetScene(JNIEnv*, jobject, jlong renderer, jlong scene) {
  std::unique_ptr<PreviewScene> owned(reinterpret_cast<PreviewScene*>(scene));
  if (!renderer) return JNI_FALSE;
  try {
    From(renderer)->Install(std::move(owned));
  } catch (...) {
    From(renderer)->Install(nullptr);
  }
  return From(renderer)->HasScene();
}

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewConfigure(
    JNIEnv*, jobject, jlong renderer, jboolean animated, jboolean reduceMotion, jboolean visible,
    jboolean fullBody, jint background) {
  if (auto* r = From(renderer)) {
    r->SetAnimated(animated);
    r->reduceMotion = reduceMotion;
    r->visible = visible;
    r->fullBody = fullBody;
    r->clear = {((background >> 16) & 255) / 255.f, ((background >> 8) & 255) / 255.f, (background & 255) / 255.f, 1};
  }
}

// Turning by hand (buttons, drags): noted as an interaction, which pauses the sway.
extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewTurn(JNIEnv*, jobject, jlong renderer, jfloat radians) {
  if (auto* r = From(renderer)) {
    r->NoteInteraction();
    r->yaw += radians;
  }
}

// ease: opening a face category (eases back while animating). Otherwise the Front button's snap.
extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewFaceFront(JNIEnv*, jobject, jlong renderer, jboolean ease) {
  if (auto* r = From(renderer)) {
    if (ease) {
      r->EaseToFront();
    } else {
      r->NoteInteraction();
      r->yaw = 0;
    }
  }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewReact(JNIEnv*, jobject, jlong renderer) {
  if (auto* r = From(renderer)) r->React();
}

extern "C" JNIEXPORT jfloat JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewYaw(JNIEnv*, jobject, jlong renderer) {
  return renderer ? From(renderer)->yaw : 0;
}

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewSetYaw(JNIEnv*, jobject, jlong renderer, jfloat yaw) {
  if (auto* r = From(renderer)) r->yaw = yaw;
}

extern "C" JNIEXPORT void JNICALL
Java_dev_kartpad_android_screens_mii_MiiNative_nativePreviewDraw(JNIEnv*, jobject, jlong renderer, jint width, jint height) {
  if (auto* r = From(renderer)) {
    try {
      r->Draw(width, height);
    } catch (...) {
      __android_log_print(ANDROID_LOG_WARN, "KartPadMiiPreview", "Frame skipped");
    }
  }
}
