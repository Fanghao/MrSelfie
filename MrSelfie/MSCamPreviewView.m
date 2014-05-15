//
//  MSCamPreviewView.m
//  MrSelfie
//
//  Created by Fanghao Chen on 5/15/14.
//  Copyright (c) 2014 MSStorm8. All rights reserved.
//

#import "MSCamPreviewView.h"
#import <AVFoundation/AVFoundation.h>

@implementation MSCamPreviewView

+ (Class)layerClass {
	return [AVCaptureVideoPreviewLayer class];
}

- (AVCaptureSession *)session {
	return [(AVCaptureVideoPreviewLayer *)[self layer] session];
}

- (void)setSession:(AVCaptureSession *)session {
	[(AVCaptureVideoPreviewLayer *)[self layer] setSession:session];
}
@end
