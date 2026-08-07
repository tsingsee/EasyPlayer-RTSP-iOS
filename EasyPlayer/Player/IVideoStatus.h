
#ifndef IVideoStatus_h
#define IVideoStatus_h

typedef enum {
    Stopped    = 0,  // 停止
    Suspend    = 1,  // 暂停
    Connecting = 2,  // 连接中
    Rendering  = 3,  // 播放中
} IVideoStatus;

/// 首帧事件码已迁移至 PlayerResultCode.h -> PLAYER_RESULT_FIRST_FRAME_TIME (902)

#endif /* IVideoStatus_h */
