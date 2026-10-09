// Editor sound effects: Mario Kart Wii menu sounds rendered once per session from the imported
// files/sound/revo_kart.brsar. Nothing is cached on disk or shipped. Without the archive the
// editor stays silent. Players use the app's existing audio session, so the iPhone/iPad silent
// switch and the game's own audio setup apply unchanged.
// The game shares the main thread with this editor, so playing must not block it: one running
// AVAudioEngine player node takes each sound as an interrupting buffer (microseconds), where
// AVAudioPlayer stop/play cost 15-90 ms per press and stuttered the game and the preview.
__asm__(".linker_option \"-framework\", \"AVFoundation\"");
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include "kartpad/audio/sound_archive.h"
#include "kartpad/mii/editor_sounds.h"
using KPSound=kartpad::mii::EditorSound;
static NSString *const KPMiiSoundsKey=@"KartPadMiiEditorSounds";
@interface KPMiiSounds : NSObject
+ (instancetype)shared;
@property(nonatomic) BOOL enabled;
- (void)prepare:(NSString*)archive;
- (void)play:(KPSound)sound;
// The editor closed: let the last sound finish, then pause the engine until the editor opens again.
- (void)suspendSoon;
@end
// Render rate of SoundArchive::Render; every buffer shares the player node's format.
static AVAudioPCMBuffer *KPMiiSoundBuffer(const kartpad::audio::Pcm &pcm,AVAudioFormat *format){
    AVAudioFrameCount frames=AVAudioFrameCount(pcm.samples.size()/2);
    if(!frames||pcm.rate!=format.sampleRate)return nil;
    AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc]initWithPCMFormat:format frameCapacity:frames];buffer.frameLength=frames;
    float *left=buffer.floatChannelData[0],*right=buffer.floatChannelData[1];
    for(AVAudioFrameCount i=0;i<frames;i++){left[i]=pcm.samples[2*i]/32768.f;right[i]=pcm.samples[2*i+1]/32768.f;}
    return buffer;
}
@implementation KPMiiSounds{
    AVAudioEngine *_engine;
    AVAudioPlayerNode *_node;
    NSArray *_buffers; // One AVAudioPCMBuffer or NSNull per EditorSound.
    KPSound _currentSound;
    CFTimeInterval _currentUntil,_retryAt;
    uint64_t _suspendToken;
    NSString *_key,*_loadingKey;
    BOOL _hasPending;
    KPSound _pending;
    CFTimeInterval _pendingTime;
}
+ (instancetype)shared{static KPMiiSounds *sounds;static dispatch_once_t once;dispatch_once(&once,^{sounds=[KPMiiSounds new];});return sounds;}
- (BOOL)enabled{id value=[NSUserDefaults.standardUserDefaults objectForKey:KPMiiSoundsKey];return value?[value boolValue]:YES;}
- (void)setEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:KPMiiSoundsKey];if(!enabled){[_node stop];_currentUntil=0;_hasPending=NO;}}
// Output device and route changes stop the engine; start it again on the next sound or here.
- (BOOL)resume{
    if(!_engine)return NO;
    if(!_engine.running&&![_engine startAndReturnError:nil]){_retryAt=CACurrentMediaTime()+1;return NO;}
    if(!_node.playing)[_node play];
    return YES;
}
- (void)engineChanged:(NSNotification*)note{dispatch_async(dispatch_get_main_queue(),^{if(note.object==self->_engine)[self resume];});}
- (void)installEngine:(AVAudioEngine*)engine node:(AVAudioPlayerNode*)node{
    if(_engine)[NSNotificationCenter.defaultCenter removeObserver:self name:AVAudioEngineConfigurationChangeNotification object:_engine];
    [_engine stop];_engine=engine;_node=node;_currentUntil=0;
    if(engine)[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(engineChanged:) name:AVAudioEngineConfigurationChangeNotification object:engine];
}
- (void)suspendSoon{
    uint64_t token=++_suspendToken;CFTimeInterval wait=std::max(0.,_currentUntil-CACurrentMediaTime())+1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,int64_t(wait*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(token==self->_suspendToken)[self->_engine pause];});
}
// Renders and starts the engine on a background queue; a reimported archive (new size or date) renders again.
- (void)prepare:(NSString*)archive{
    _suspendToken++;
    NSDictionary *attributes=archive?[NSFileManager.defaultManager attributesOfItemAtPath:archive error:nil]:nil;
    if(!attributes){_buffers=nil;_key=nil;[self installEngine:nil node:nil];return;}
    NSString *key=[NSString stringWithFormat:@"%@|%@|%f",archive,attributes[NSFileSize],attributes.fileModificationDate.timeIntervalSince1970];
    if([key isEqual:_key]){if(_buffers&&self.enabled)[self resume];return;}
    if([key isEqual:_loadingKey])return;
    _loadingKey=key;
    static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("dev.kartpad.mii-sounds",DISPATCH_QUEUE_SERIAL);});
    dispatch_async(queue,^{@autoreleasepool{
        NSMutableArray *buffers=[NSMutableArray array];
        AVAudioFormat *format=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:32000 channels:2];
        NSData *data=[NSData dataWithContentsOfFile:archive options:NSDataReadingMappedIfSafe error:nil];
        try{
            if(!data)throw std::invalid_argument("Sound archive unavailable.");
            kartpad::audio::SoundArchive sounds(Bytes(data));
            for(const char *name:kartpad::mii::EditorSoundNames){
                id buffer=nil;
                try{buffer=KPMiiSoundBuffer(sounds.Render(name),format);}catch(const std::exception&){/* That one sound stays silent. */}
                [buffers addObject:buffer?:NSNull.null];
            }
        }catch(const std::exception&){buffers=nil;}
        AVAudioEngine *engine=nil;AVAudioPlayerNode *node=nil;
        if(buffers){
            engine=[AVAudioEngine new];node=[AVAudioPlayerNode new];[engine attachNode:node];
            [engine connect:node to:engine.mainMixerNode format:format];node.volume=.8f;
            if([engine startAndReturnError:nil])[node play];
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if(![self->_loadingKey isEqual:key]){[engine stop];return;}
            self->_loadingKey=nil;self->_key=key;self->_buffers=buffers;[self installEngine:engine node:node];
            // A sound asked for while rendering (the editor opening) still plays if it is recent.
            if(self->_hasPending&&CACurrentMediaTime()-self->_pendingTime<1.5)[self play:self->_pending];
            self->_hasPending=NO;
        });
    }});
}
- (void)play:(KPSound)sound{
    if(!self.enabled)return;
    if(!_buffers){if(_loadingKey){_pending=sound;_pendingTime=CACurrentMediaTime();_hasPending=YES;}return;}
    AVAudioPCMBuffer *buffer=_buffers[size_t(sound)];if(![buffer isKindOfClass:AVAudioPCMBuffer.class])return;
    // Pointer hover never cuts off another sound; anything else replaces whatever is playing.
    CFTimeInterval now=CACurrentMediaTime();
    if(sound==KPSound::Hover&&now<_currentUntil&&_currentSound!=KPSound::Hover)return;
    _suspendToken++;
    if(!_engine.running||!_node.playing){if(now<_retryAt||![self resume])return;}
    [_node scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferInterrupts completionHandler:nil];
    _currentSound=sound;_currentUntil=now+buffer.frameLength/buffer.format.sampleRate;
}
@end
static void KPPlay(KPSound sound){[[KPMiiSounds shared] play:sound];}
