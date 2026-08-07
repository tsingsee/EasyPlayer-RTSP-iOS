
#ifndef PlayerResultCode_h
#define PlayerResultCode_h

/**
 * ResultReceiver 回调 code 说明（与 Android 对齐）
 * 1    连接中
 * 3    连接成功
 * 4    连接失败
 * 5    切换分辨率
 * 6    流中断
 * 7    重连中
 * 8    无数据
 * 9    超时
 * 10   连接退出
 * 900  视频分辨率
 * 901  解码方式（data: 0软解 1硬解）
 * 902  首帧时间（data=毫秒）
 * 903  解码失败
 * 904  不支持该视频编码
 * 905  不支持该音频格式
 * 906  重连耗时（data=毫秒，count=第几次重连）
 * 907  播放成功率（仅首帧成功时回调；data=成功率%；count=s_count；total=本会话请求次数）
 *       message 形如：{success:100%,s_count:1,total:1}
 * 908  视频编码（data: 264=H264 265=H265）
 */
#define PLAYER_RESULT_CONNECTING                1
#define PLAYER_RESULT_CONNECTED                 3
#define PLAYER_RESULT_CONNECT_FAIL              4
#define PLAYER_RESULT_CHANGE_RESOLUTION         5
#define PLAYER_RESULT_STREAM_ABORT              6
#define PLAYER_RESULT_RECONN                    7
#define PLAYER_RESULT_NO_DATA                   8
#define PLAYER_RESULT_TIMEOUT                   9
#define PLAYER_RESULT_EXIT                     10
#define PLAYER_RESULT_VIDEO_RESOLUTION        900
#define PLAYER_RESULT_DECODE_MODE             901
#define PLAYER_RESULT_FIRST_FRAME_TIME        902
#define PLAYER_RESULT_DECODE_FAIL             903
#define PLAYER_RESULT_VIDEO_CODEC_UNSUPPORTED 904
#define PLAYER_RESULT_AUDIO_CODEC_UNSUPPORTED 905
#define PLAYER_RESULT_RECONN_COST             906
#define PLAYER_RESULT_PLAY_SUCCESS_RATE       907
#define PLAYER_RESULT_VIDEO_CODEC             908

#define PLAYER_DECODE_MODE_SW                 0
#define PLAYER_DECODE_MODE_HW                 1
#define PLAYER_VIDEO_CODEC_H264             264
#define PLAYER_VIDEO_CODEC_H265             265

#endif /* PlayerResultCode_h */
