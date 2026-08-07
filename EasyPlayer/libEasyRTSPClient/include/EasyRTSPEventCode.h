
#ifndef EasyRTSPEventCode_h
#define EasyRTSPEventCode_h

/*
 * EasyRTSPClient SDK 事件回调码（frameType == EASY_SDK_EVENT_FRAME_FLAG 时 frameInfo->codec）
 * 参照 Android NVSourceAPI.h
 */
#define EVENT_CODEC_ERROR              0x63657272  /* "cerr" */
#define EVENT_CODEC_RECONN             0x7265636F  /* "reco" */
#define EVENT_CODEC_EXIT               0x65786974  /* "exit" */
#define EVENT_CODEC_FILE_INFO          0x696E666F  /* "info" */
#define EVENT_CODEC_CONNECTING         0x65767401  /* "evt\x01" */
#define EVENT_CODEC_CONNECTED          0x65767402  /* "evt\x02" */
#define EVENT_CODEC_CONNECT_FAIL       0x65767403  /* "evt\x03" */
#define EVENT_CODEC_FIRST_FRAME        0x65767404  /* "evt\x04" */
#define EVENT_CODEC_STREAM_ABORT       0x65767405  /* "evt\x05" */
#define EVENT_CODEC_CHANGE_RESOLUTION  0x65767406  /* "evt\x06" */
#define EVENT_CODEC_NO_DATA            0x65767407  /* "evt\x07" */
#define EVENT_CODEC_CONNECT_TIMEOUT    0x65767408  /* "evt\x08" */

#endif /* EasyRTSPEventCode_h */
