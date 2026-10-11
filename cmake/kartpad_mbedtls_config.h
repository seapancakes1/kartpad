/* Mbed TLS options for the phone controllers' WebRTC link (cmake/KartPadPhoneLink.cmake), on top of
 * Mbed TLS's defaults. libdatachannel's DTLS transport calls the DTLS-SRTP functions even without
 * media, so they have to exist. */
#define MBEDTLS_SSL_DTLS_SRTP
