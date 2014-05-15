//
//  MSCamPreviewView.h
//  MrSelfie
//
//  Created by Fanghao Chen on 5/15/14.
//  Copyright (c) 2014 MSStorm8. All rights reserved.
//

#import <UIKit/UIKit.h>

@class AVCaptureSession;

@interface MSCamPreviewView : UIView

@property (nonatomic) AVCaptureSession *session;

@end
