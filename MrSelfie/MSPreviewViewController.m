//
//  MSPreviewViewController.m
//  MrSelfie
//
//  Created by Weixi Yen on 5/15/14.
//  Copyright (c) 2014 MSStorm8. All rights reserved.
//

#import "MSPreviewViewController.h"
#import "Mixpanel.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVFoundation.h>

static NSString *const GIF_FILE_NAME = @"animated.gif";

@interface MSPreviewViewController ()

@property (nonatomic, strong) IBOutlet UIImageView *imageView;
@property (nonatomic, strong) IBOutlet UIView *buttonContainerView;
@property (nonatomic, strong) IBOutlet UIButton *shareButton;
@property (nonatomic, strong) IBOutlet UIButton *retakeButton;
@property (nonatomic) int currentIndex;
@property (nonatomic) NSURL *fileUrl;
@property (nonatomic, strong) UIImage *firstImage;
@property (nonatomic, strong) AVAssetWriter *videoWriter;

- (IBAction)share:(id)sender;
- (IBAction)retake:(id)sender;

@end


@implementation MSPreviewViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.firstImage = [self.photos objectAtIndex:0];
    
    NSMutableArray *arr = [NSMutableArray array];
    
    for (int i=0; i<15; i++) {
        [arr addObject:self.firstImage];
    }
    
    for (UIImage *img in self.photos) {
        [arr addObject:img];
    }
    
    self.photos = arr;
    
    self.currentIndex = self.photos.count - 1;
    [self showNextImage];
    
    [self createVideo];
    
    [self trackShotTaken];
}

- (void)showNextImage {
    [self.imageView setImage:[self.photos objectAtIndex:self.currentIndex]];
    
    // reached the end of slideshow
    if (self.currentIndex == 0) {
        self.currentIndex = self.photos.count - 1;
        [self performSelector:@selector(showNextImage) withObject:nil afterDelay:3];
        return;
    }
    
    // default case, increment and show the next image
    self.currentIndex -= 1;
    [self performSelector:@selector(showNextImage) withObject:nil afterDelay:0.2];
}

- (IBAction)share:(id)sender {
    NSString *string = @"Taken with Shots";
    
    // open up fb share
    UIActivityViewController *activityViewController =
    [[UIActivityViewController alloc] initWithActivityItems:@[string, self.fileUrl]
                                      applicationActivities:nil];
    
    [activityViewController setCompletionHandler:^(NSString *activityType, BOOL completed) {
        NSString *shareMediaType = @"NONE";
        
        if([activityType isEqualToString: UIActivityTypeMail]){
            shareMediaType = @"MAIL";
        }
        
        if([activityType isEqualToString: UIActivityTypePostToFacebook]){
            shareMediaType = @"FACEBOOK";
        }
        
        if([activityType isEqualToString: UIActivityTypePostToTwitter]){
            shareMediaType = @"TWITTER";
        }
        
        if([activityType isEqualToString: UIActivityTypeSaveToCameraRoll]){
            shareMediaType = @"SAVE_TO_CAMERA";
        }
        
        if([activityType isEqualToString: UIActivityTypeCopyToPasteboard]){
            shareMediaType = @"COPIED_TO_PASTEBOARD";
        }
        
        if([activityType isEqualToString: UIActivityTypeMessage]){
            shareMediaType = @"MESSAGE";
        }
        
        [[Mixpanel sharedInstance] track:@"SUCCESSFULLY_SHARED_VIDEO" properties:@{
                                                                                   @"TYPE": shareMediaType,
                                                                                   }];
        
        NSLog(@"SHARE DONE!");
    }];

    [self presentViewController:activityViewController
                                       animated:YES
                                     completion:nil];
    
    [[Mixpanel sharedInstance] track:@"CLICKED_SHARE_BUTTON"];
}

- (IBAction)retake:(id)sender {
    __weak __typeof(self) weakSelf = self;
    [self dismissViewControllerAnimated:NO completion:^(void){
        weakSelf.photos = nil;
    }];
    
    [[Mixpanel sharedInstance] track:@"CLICKED_RETAKE_BUTTON"];
}

- (void)createAnimatedGif {
    int frameCount = self.photos.count;
    
    NSDictionary *fileProperties = @{
                                 (__bridge id)kCGImagePropertyGIFDictionary: @{
                                         (__bridge id)kCGImagePropertyGIFLoopCount: @0, // 0 means loop forever
                                         }
                                 };
    
    NSDictionary *frameProperties = @{
                                      (__bridge id)kCGImagePropertyGIFDictionary: @{
                                              (__bridge id)kCGImagePropertyGIFDelayTime: @0.2f, // a float (not double!) in seconds, rounded to centiseconds in the GIF data
                                              }
                                      };
    
    NSDictionary *finalFrameProperties = @{
                                      (__bridge id)kCGImagePropertyGIFDictionary: @{
                                              (__bridge id)kCGImagePropertyGIFDelayTime: @3.0f, // a float (not double!) in seconds, rounded to centiseconds in the GIF data
                                              }
                                      };
    
    NSURL *documentsDirectoryURL = [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *fileURL = [documentsDirectoryURL URLByAppendingPathComponent:GIF_FILE_NAME];
    
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)fileURL, kUTTypeGIF, frameCount, NULL);
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)fileProperties);
    
    for (int i = self.photos.count - 1; i >= 0; i--) {
        @autoreleasepool {
            UIImage *image = [self.photos objectAtIndex:i];
            
            if (i == 0) {
                CGImageDestinationAddImage(destination, image.CGImage, (__bridge CFDictionaryRef)finalFrameProperties);
            } else {
                CGImageDestinationAddImage(destination, image.CGImage, (__bridge CFDictionaryRef)frameProperties);
            }
        }
    }
    
    if (!CGImageDestinationFinalize(destination)) {
        NSLog(@"failed to finalize image destination");
    }
    
    CFRelease(destination);
    NSLog(@"%@", fileURL);
    self.fileUrl = fileURL;
//    [[[ALAssetsLibrary alloc] init] writeImageDataToSavedPhotosAlbum:[NSData dataWithContentsOfURL:fileURL] metadata:nil completionBlock:nil];
}





- (void)createVideo {
    
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        //Background Thread
        
        ///////////// setup OR function def if we move this to a separate function ////////////
        // this should be moved to its own function, that can take an imageArray, videoOutputPath, etc...
        //    - (void)exportImages:(NSMutableArray *)imageArray
        // asVideoToPath:(NSString *)videoOutputPath
        // withFrameSize:(CGSize)imageSize
        // framesPerSecond:(NSUInteger)fps {
        
        NSError *error = nil;
        
        
        // set up file manager, and file videoOutputPath, remove "test_output.mp4" if it exists...
        //NSString *videoOutputPath = @"/Users/someuser/Desktop/test_output.mp4";
        NSFileManager *fileMgr = [NSFileManager defaultManager];
        NSString *documentsDirectory = [NSHomeDirectory()
                                        stringByAppendingPathComponent:@"Documents"];
        NSString *videoOutputPath = [documentsDirectory stringByAppendingPathComponent:@"selfie.mp4"];
        //NSLog(@"-->videoOutputPath= %@", videoOutputPath);
        // get rid of existing mp4 if exists...
        if ([fileMgr removeItemAtPath:videoOutputPath error:&error] != YES)
            NSLog(@"Unable to delete file: %@", [error localizedDescription]);
        
        CGSize imageSize = CGSizeMake(self.firstImage.size.width, self.firstImage.size.height);
        NSUInteger fps = 15;
        
        
        
        //////////////     end setup    ///////////////////////////////////
        
        NSLog(@"Start building video from defined frames.");
        
        self.videoWriter = [[AVAssetWriter alloc] initWithURL:
                            [NSURL fileURLWithPath:videoOutputPath] fileType:AVFileTypeQuickTimeMovie
                                                        error:&error];
        NSParameterAssert(self.videoWriter);
        
        NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                       AVVideoCodecH264, AVVideoCodecKey,
                                       [NSNumber numberWithInt:imageSize.width], AVVideoWidthKey,
                                       [NSNumber numberWithInt:imageSize.height], AVVideoHeightKey,
                                       nil];
        
        AVAssetWriterInput* videoWriterInput = [AVAssetWriterInput
                                                assetWriterInputWithMediaType:AVMediaTypeVideo
                                                outputSettings:videoSettings];
        
        
        AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
                                                         assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoWriterInput
                                                         sourcePixelBufferAttributes:nil];
        
        NSParameterAssert(videoWriterInput);
        NSParameterAssert([self.videoWriter canAddInput:videoWriterInput]);
        videoWriterInput.expectsMediaDataInRealTime = YES;
        [self.videoWriter addInput:videoWriterInput];
        
        //Start a session:
        [self.videoWriter startWriting];
        [self.videoWriter startSessionAtSourceTime:kCMTimeZero];
        
        CVPixelBufferRef buffer = NULL;
        
        //convert uiimage to CGImage.
        int frameCount = 0;
        double numberOfSecondsPerFrame = 0.2;
        double frameDuration = fps * numberOfSecondsPerFrame;
        
        //for(VideoFrame * frm in imageArray)
        NSLog(@"**************************************************");
        
        for (int i=self.photos.count-1; i>=0; i--)
        {
            UIImage *img = self.photos[i];
            //UIImage * img = frm._imageFrame;
            if (buffer) {
                CVBufferRelease(buffer);
            }
            
            buffer = [self pixelBufferFromCGImage:[img CGImage]];
            
            BOOL append_ok = NO;
            int j = 0;
            while (!append_ok && j < 30) {
                if (adaptor.assetWriterInput.readyForMoreMediaData)  {
                    //print out status:
                    NSLog(@"Processing video frame (%d,%d)",frameCount,(int)[self.photos count]);
                    
                    CMTime frameTime = CMTimeMake(frameCount*frameDuration,(int32_t) fps);
                    
                    append_ok = [adaptor appendPixelBuffer:buffer withPresentationTime:frameTime];
                    if(!append_ok){
                        NSError *error = self.videoWriter.error;
                        if(error!=nil) {
                            NSLog(@"Unresolved error %@,%@.", error, [error userInfo]);
                        }
                    }
                }
                else {
                    printf("adaptor not ready %d, %d\n", frameCount, j);
                    [NSThread sleepForTimeInterval:0.1];
                }
                j++;
            }
            if (!append_ok) {
                printf("error appending image %d times %d\n, with error.", frameCount, j);
            }
            frameCount++;
        }
        NSLog(@"**************************************************");
        
        //Finish the session:
        [videoWriterInput markAsFinished];
        [self.videoWriter finishWritingWithCompletionHandler:^(void) {
            CVBufferRelease(buffer);
            self.videoWriter = nil;
        }];
        NSLog(@"Write Ended");
        
        self.fileUrl = [NSURL fileURLWithPath:videoOutputPath];
        NSLog(@"%@", self.fileUrl);
    });
    
    
}

- (CVPixelBufferRef) pixelBufferFromCGImage: (CGImageRef) image {
    CGSize size = CGSizeMake(self.firstImage.size.width, self.firstImage.size.height);
    
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithBool:YES], kCVPixelBufferCGImageCompatibilityKey,
                             [NSNumber numberWithBool:YES], kCVPixelBufferCGBitmapContextCompatibilityKey,
                             nil];
    CVPixelBufferRef pxbuffer = NULL;
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          size.width,
                                          size.height,
                                          kCVPixelFormatType_32ARGB,
                                          (__bridge CFDictionaryRef) options,
                                          &pxbuffer);
    
    if (status != kCVReturnSuccess){
        NSLog(@"Failed to create pixel buffer");
    }
    
    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
    
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, size.width,
                                                 size.height, 8, 4*size.width, rgbColorSpace,
                                                 kCGImageAlphaPremultipliedFirst);
    
    CGAffineTransform transform = CGAffineTransformMakeTranslation(size.width, 0.0);
    transform = CGAffineTransformScale(transform, -1.0, 1.0);
    CGContextConcatCTM(context, transform);
    
    //kCGImageAlphaNoneSkipFirst);
    CGContextConcatCTM(context, CGAffineTransformMakeRotation(0));
    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(image),
                                           CGImageGetHeight(image)), image);
    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    
    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    
    return pxbuffer;
}


#pragma mark - tracking

- (void)trackShotTaken {
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    
    NSString *orientationString = @"LANDSCAPE";

    if (orientation == UIDeviceOrientationPortrait || orientation == UIDeviceOrientationPortraitUpsideDown) {
        orientationString = @"PORTRAIT";
    }
    
    NSNumber *length = [NSNumber numberWithLong:(self.photos.count - 15)];
    
    [[Mixpanel sharedInstance] track:@"SHOT_TAKEN" properties:@{
                                                                @"LENGTH": length,
                                                                @"ORIENTATION": orientationString,
                                                                }];
}

@end
