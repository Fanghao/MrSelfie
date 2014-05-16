//
//  MSPreviewViewController.m
//  MrSelfie
//
//  Created by Weixi Yen on 5/15/14.
//  Copyright (c) 2014 MSStorm8. All rights reserved.
//

#import "MSPreviewViewController.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>


@interface MSPreviewViewController ()

@property (nonatomic, strong) IBOutlet UIImageView *imageView;
@property (nonatomic, strong) IBOutlet UIView *buttonContainerView;
@property (nonatomic, strong) IBOutlet UIButton *shareButton;
@property (nonatomic, strong) IBOutlet UIButton *retakeButton;
@property (nonatomic) int currentIndex;

- (IBAction)share:(id)sender;
- (IBAction)retake:(id)sender;

@end


@implementation MSPreviewViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
//    self.photos = @[
//                    [UIImage imageNamed:@"IMG_2455.jpg"],
//                    [UIImage imageNamed:@"IMG_2454.jpg"],
//                    [UIImage imageNamed:@"IMG_2453.jpg"],
//                    [UIImage imageNamed:@"IMG_2452.jpg"],
//                    [UIImage imageNamed:@"IMG_2451.jpg"],
//                    [UIImage imageNamed:@"IMG_2450.jpg"],
//                    [UIImage imageNamed:@"IMG_2449.jpg"],
//                    [UIImage imageNamed:@"IMG_2448.jpg"],
//                    [UIImage imageNamed:@"IMG_2447.jpg"],
//                    [UIImage imageNamed:@"IMG_2446.jpg"],
//                    [UIImage imageNamed:@"IMG_2445.jpg"],
//                    [UIImage imageNamed:@"IMG_2444.jpg"],
//                    [UIImage imageNamed:@"IMG_2443.jpg"],
//                    ];

    self.currentIndex = self.photos.count - 1;
    [self showNextImage];
    
    [self createAnimatedGif];
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
    NSLog(@"share...");
    
    // open up fb share
}

- (IBAction)retake:(id)sender {
    [self dismissViewControllerAnimated:NO completion:^(void){
        
    }];
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
    NSURL *fileURL = [documentsDirectoryURL URLByAppendingPathComponent:@"animated.gif"];
    
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)fileURL, kUTTypeGIF, frameCount, NULL);
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)fileProperties);
    
    for (int i = self.photos.count - 1; i >= 0; i--) {
        NSLog(@"%d %d", i, self.photos.count);
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
    
    NSLog(@"url=%@", fileURL);
    [[[ALAssetsLibrary alloc] init] writeImageDataToSavedPhotosAlbum:[NSData dataWithContentsOfURL:fileURL] metadata:nil completionBlock:nil];
}

@end
