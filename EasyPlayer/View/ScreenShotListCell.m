//
//  BrandShopCell.m
//  Easy
//
//  Created by leo on 2017/11/6.
//  Copyright © 2017年 leo. All rights reserved.
//

#import "ScreenShotListCell.h"
#import "Masonry.h"

@implementation ScreenShotListCell

+ (instancetype)cellWithTableView:(UITableView *)tableView {
    static NSString *identifier = @"ScreenShotListCell";
    // 1.缓存中
    ScreenShotListCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    // 2.创建
    if (cell == nil) {
        cell = [[ScreenShotListCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

/**
 *  构造方法(在初始化对象的时候会调用)
 *  一般在这个方法中添加需要显示的子控件
 */
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        self.backgroundColor = [UIColor grayColor];
        UIView *lineView = [[UIView alloc] init];
        lineView.backgroundColor = UIColorFromRGB(0xf2f2f2);
        [self addSubview:lineView];
        [lineView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(@0);
            make.right.equalTo(@0);
            make.bottom.equalTo(@0);
            make.height.equalTo(@5);
        }];
        
        _infoIV = [[UIImageView alloc] init];
        _infoIV.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_infoIV];
        [_infoIV mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(@0);
            make.right.equalTo(@0);
            make.bottom.equalTo(@(-5));
            make.top.equalTo(@0);
        }];

    }
    
    return self;
}

@end
