
#import "BaseViewController.h"
#import "URLModel.h"

/**
 视频播放
 */
@interface VideoPlayerController : BaseViewController

@property (nonatomic, strong) URLModel *model;

@property(nonatomic,strong) UITextView *statusView;

@end


