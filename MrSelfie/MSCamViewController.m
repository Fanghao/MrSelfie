//
//  MSCamViewController.m
//  MrSelfie
//
//  Created by Fanghao Chen on 5/15/14.
//  Copyright (c) 2014 MSStorm8. All rights reserved.
//

#import "MSCamViewController.h"
#import "MSCamPreviewView.h"
#import "MSPreviewViewController.h"
#import "Mixpanel.h"
#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaPlayer/MediaPlayer.h>
#import "RBVolumeButtons.h"

#define ImageCapacity 10
#define SnapInterval 0.6 // SnapInterval > 0.6 will cancel the shutter sounds

static void * CapturingStillImageContext = &CapturingStillImageContext;
static void * SessionRunningAndDeviceAuthorizedContext = &SessionRunningAndDeviceAuthorizedContext;
static SystemSoundID soundID = 0;

@interface MSCamViewController ()

@property (strong, nonatomic) IBOutlet UIView *stillButtonView;
@property (strong, nonatomic) IBOutlet UIButton *stillButton;
@property (strong, nonatomic) IBOutlet UIButton *cameraButton;
@property (strong, nonatomic) IBOutlet MSCamPreviewView *previewView;

// Session management.
@property (nonatomic) dispatch_queue_t sessionQueue; // Communicate with the session and other session objects on this queue.
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (nonatomic) AVCaptureStillImageOutput *stillImageOutput;

// Utilities.
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID;
@property (nonatomic, getter = isDeviceAuthorized) BOOL deviceAuthorized;
@property (nonatomic, readonly, getter = isSessionRunningAndDeviceAuthorized) BOOL sessionRunningAndDeviceAuthorized;
@property (nonatomic) BOOL lockInterfaceRotation;
@property (nonatomic) id runtimeErrorHandlingObserver;

@property (nonatomic, strong) NSMutableArray *imageArrays;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL isUserTapped;

@property (nonatomic, strong) RBVolumeButtons *buttonStealer;

@end

@implementation MSCamViewController


- (BOOL)isSessionRunningAndDeviceAuthorized {
	return [[self session] isRunning] && [self isDeviceAuthorized];
}

+ (NSSet *)keyPathsForValuesAffectingSessionRunningAndDeviceAuthorized {
	return [NSSet setWithObjects:@"session.running", @"deviceAuthorized", nil];
}

#pragma mark - Overwritten methods

- (void)viewDidLoad {
	[super viewDidLoad];
    
    self.navigationController.navigationBar.hidden = YES;
    self.imageArrays = [NSMutableArray arrayWithCapacity:ImageCapacity];
    
    [self orientationChanged];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationChanged)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    
	// Create the AVCaptureSession
	AVCaptureSession *session = [[AVCaptureSession alloc] init];
	[self setSession:session];
	
	// Setup the preview view
	[[self previewView] setSession:session];
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(focusAndExposeTap:)];
    [[self previewView] addGestureRecognizer:tapGesture];
	
	// Check for device authorization
	[self checkDeviceAuthorizationStatus];
	
	// In general it is not safe to mutate an AVCaptureSession or any of its inputs, outputs, or connections from multiple threads at the same time.
	// Why not do all of this on the main queue?
	// -[AVCaptureSession startRunning] is a blocking call which can take a long time. We dispatch session setup to the sessionQueue so that the main queue isn't blocked (which keeps the UI responsive).
	
	dispatch_queue_t sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
	[self setSessionQueue:sessionQueue];
	
	dispatch_async(sessionQueue, ^{
		[self setBackgroundRecordingID:UIBackgroundTaskInvalid];
		
		NSError *error = nil;
		
		AVCaptureDevice *videoDevice = [MSCamViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:AVCaptureDevicePositionFront];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
		
		if (error)
		{
			NSLog(@"%@", error);
		}
		
		if ([session canAddInput:videoDeviceInput])
		{
			[session addInput:videoDeviceInput];
			[self setVideoDeviceInput:videoDeviceInput];
            
			dispatch_async(dispatch_get_main_queue(), ^{
				// Why are we dispatching this to the main queue?
				// Because AVCaptureVideoPreviewLayer is the backing layer for MSPreviewView and UIView can only be manipulated on main thread.
				// Note: As an exception to the above rule, it is not necessary to serialize video orientation changes on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
                
				[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)[self interfaceOrientation]];
			});
		}
		
		AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
		if ([session canAddOutput:stillImageOutput])
		{
            if (stillImageOutput.stillImageStabilizationSupported) {
                stillImageOutput.automaticallyEnablesStillImageStabilizationWhenAvailable = YES;
            }
			[stillImageOutput setOutputSettings:@{AVVideoCodecKey : AVVideoCodecJPEG}];
			[session addOutput:stillImageOutput];
			[self setStillImageOutput:stillImageOutput];
		}
	});
    
    [[Mixpanel sharedInstance] track:@"OPENED_CAMERA"];
}

- (void)viewWillAppear:(BOOL)animated {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becomeInactive) name:@"WILL_RESIGN_ACTIVE" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becomeActiveFromBackground) name:@"DID_BECOME_ACTIVE" object:nil];
    
    [self createShutterSound];
    self.stillButton.enabled = YES;

    if (!self.buttonStealer) {
        self.buttonStealer = [[RBVolumeButtons alloc] init];
    }
    
    __weak __typeof(self) weakSelf = self;
    self.buttonStealer.upBlock = ^{
        [weakSelf stillButtonPressed:nil];
        [weakSelf.buttonStealer stopStealingVolumeButtonEvents];
    };
    self.buttonStealer.downBlock = ^{
        [weakSelf stillButtonPressed:nil];
        [weakSelf.buttonStealer stopStealingVolumeButtonEvents];
    };

    [self.buttonStealer startStealingVolumeButtonEvents];

    [self performSelector:@selector(startTimer) withObject:nil afterDelay:SnapInterval];
    self.isUserTapped = NO;
    [[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)[self interfaceOrientation]];
    
	dispatch_async([self sessionQueue], ^{
		[self addObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:SessionRunningAndDeviceAuthorizedContext];
		[self addObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:CapturingStillImageContext];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
		
		__weak __typeof(self)weakSelf = self;
		[self setRuntimeErrorHandlingObserver:[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:[self session] queue:nil usingBlock:^(NSNotification *note) {
			MSCamViewController *strongSelf = weakSelf;
			dispatch_async([strongSelf sessionQueue], ^{
				// Manually restarting the session since it must have been stopped due to an error.
				[[strongSelf session] startRunning];
			});
		}]];
		[[self session] startRunning];
	});
}

- (void)viewDidDisappear:(BOOL)animated {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"WILL_RESIGN_ACTIVE" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"DID_BECOME_ACTIVE" object:nil];
    
	dispatch_async([self sessionQueue], ^{
		[[self session] stopRunning];
		
		[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
		[[NSNotificationCenter defaultCenter] removeObserver:[self runtimeErrorHandlingObserver]];
		
		[self removeObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" context:SessionRunningAndDeviceAuthorizedContext];
		[self removeObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" context:CapturingStillImageContext];
	});
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

# pragma mark - APP state

- (void)becomeActiveFromBackground {
    [self performSelector:@selector(startTimer) withObject:nil afterDelay:SnapInterval];
}

- (void)becomeInactive {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self stopTimer];
    [self.imageArrays removeAllObjects];
}

#pragma mark - timer

- (void)startTimer {
    if (self.timer == nil) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:SnapInterval target:self selector:@selector(snapStillImage) userInfo:nil repeats:YES];
    }
}

- (void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}

- (BOOL)prefersStatusBarHidden {
	return YES;
}

#pragma mark - rotation

- (BOOL)shouldAutorotate {
	// Disable autorotation of the interface when recording is in progress.
	return ![self lockInterfaceRotation];
}

- (NSUInteger)supportedInterfaceOrientations {
	return UIInterfaceOrientationMaskAll;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
    [UIView setAnimationsEnabled:NO];
	[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)toInterfaceOrientation];
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    [UIView setAnimationsEnabled:YES];
}

- (void)orientationChanged {
    UIDevice *device = [UIDevice currentDevice];
    switch (device.orientation) {
        case UIDeviceOrientationPortrait:
            self.stillButtonView.transform = CGAffineTransformIdentity;
            self.stillButtonView.frame = CGRectMake(0, self.view.frame.size.height - self.stillButtonView.bounds.size.height, self.stillButtonView.bounds.size.width, self.stillButtonView.bounds.size.height);
            break;
        case UIDeviceOrientationLandscapeLeft:
            self.stillButtonView.transform = CGAffineTransformMakeRotation(-M_PI_2);
            self.stillButtonView.center = CGPointMake(self.view.frame.size.width - self.stillButtonView.frame.size.width / 2, self.view.frame.size.height / 2);
            break;
        case UIDeviceOrientationLandscapeRight:
            self.stillButtonView.transform = CGAffineTransformMakeRotation(M_PI_2);
            self.stillButtonView.center = CGPointMake(self.stillButtonView.frame.size.width / 2, self.view.frame.size.height / 2);
            break;
        default:
            break;
    }
}

#pragma mark - Private Methods

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if (context == CapturingStillImageContext)
	{
		BOOL isCapturingStillImage = [change[NSKeyValueChangeNewKey] boolValue];
		
		if (isCapturingStillImage && self.isUserTapped)
		{
			[self runStillImageCaptureAnimation];
		}
	}
	else if (context == SessionRunningAndDeviceAuthorizedContext)
	{
		BOOL isRunning = [change[NSKeyValueChangeNewKey] boolValue];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			if (isRunning)
			{
				[[self cameraButton] setEnabled:YES];
				[[self stillButton] setEnabled:YES];
			}
			else
			{
				[[self cameraButton] setEnabled:NO];
				[[self stillButton] setEnabled:NO];
			}
		});
	}
	else
	{
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

#pragma mark IBActions

- (IBAction)cameraButtonPressed:(id)sender {
	[[self cameraButton] setEnabled:NO];
	[[self stillButton] setEnabled:NO];
	
	dispatch_async([self sessionQueue], ^{
		AVCaptureDevice *currentVideoDevice = [[self videoDeviceInput] device];
		AVCaptureDevicePosition preferredPosition = AVCaptureDevicePositionUnspecified;
		AVCaptureDevicePosition currentPosition = [currentVideoDevice position];
		
		switch (currentPosition)
		{
			case AVCaptureDevicePositionUnspecified:
				preferredPosition = AVCaptureDevicePositionBack;
				break;
			case AVCaptureDevicePositionBack:
				preferredPosition = AVCaptureDevicePositionFront;
				break;
			case AVCaptureDevicePositionFront:
				preferredPosition = AVCaptureDevicePositionBack;
				break;
		}
		
		AVCaptureDevice *videoDevice = [MSCamViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:preferredPosition];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];
		
		[[self session] beginConfiguration];
		
		[[self session] removeInput:[self videoDeviceInput]];
		if ([[self session] canAddInput:videoDeviceInput])
		{
			[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];
			
			[MSCamViewController setFlashMode:AVCaptureFlashModeAuto forDevice:videoDevice];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:videoDevice];
			
			[[self session] addInput:videoDeviceInput];
			[self setVideoDeviceInput:videoDeviceInput];
		}
		else
		{
			[[self session] addInput:[self videoDeviceInput]];
		}
		
		[[self session] commitConfiguration];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			[[self cameraButton] setEnabled:YES];
			[[self stillButton] setEnabled:YES];
		});
	});
}

- (void)createShutterSound {
    if (soundID == 0) {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"photoShutter2" ofType:@"caf"];
        NSURL *filePath = [NSURL fileURLWithPath:path isDirectory:NO];
        AudioServicesCreateSystemSoundID((__bridge CFURLRef)filePath, &soundID);
    }
}

- (IBAction)stillButtonPressed:(id)sender {
    self.isUserTapped = YES;
    self.stillButton.enabled = NO;
    [self stopTimer];
    [self snapStillImage];
}

- (void)snapStillImage {
    dispatch_async([self sessionQueue], ^{
		// Update the orientation on the still image output video connection before capturing.
		[[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
		
		// Flash set to Auto for Still Capture
		[MSCamViewController setFlashMode:AVCaptureFlashModeAuto forDevice:[[self videoDeviceInput] device]];
		
        if (!self.isUserTapped) {
            AudioServicesPlaySystemSound(soundID);
        } else {
            AudioServicesDisposeSystemSoundID(soundID);
            soundID = 0;
        }
        
		// Capture a still image.
		[[self stillImageOutput] captureStillImageAsynchronouslyFromConnection:[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
			
			if (imageDataSampleBuffer)
			{
				NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
				UIImage *image = [[UIImage alloc] initWithData:imageData];
                [self.imageArrays insertObject:image atIndex:0];
                if (self.imageArrays.count > ImageCapacity) {
                    UIImage *lastImage = [self.imageArrays lastObject];
                    [self.imageArrays removeLastObject];
                    lastImage = nil;
                }
                
                if (self.isUserTapped) {
                    MSPreviewViewController *previewVC = [self.storyboard instantiateViewControllerWithIdentifier:@"MSPreviewViewController"];
                    for (int i = 0; i < self.imageArrays.count; i++) {
                        UIImage *image = (UIImage *)self.imageArrays[i];
                        UIImage *orientedImage = [self fixOrientationOfImage:image];
                        [self.imageArrays replaceObjectAtIndex:i withObject:orientedImage];
                    }
                    [previewVC setPhotos:self.imageArrays];
                    __weak __typeof(self) weakSelf = self;
                    [self.navigationController presentViewController:previewVC animated:NO completion:^{
                        [weakSelf.imageArrays removeAllObjects];
                    }];
                }
//                // TODO: remove
//				[[[ALAssetsLibrary alloc] init] writeImageToSavedPhotosAlbum:[image CGImage] orientation:(ALAssetOrientation)[image imageOrientation] completionBlock:nil];
			}
		}];
	});
}

- (IBAction)focusAndExposeTap:(UIGestureRecognizer *)gestureRecognizer {
	CGPoint devicePoint = [(AVCaptureVideoPreviewLayer *)[[self previewView] layer] captureDevicePointOfInterestForPoint:[gestureRecognizer locationInView:[gestureRecognizer view]]];
	[self focusWithMode:AVCaptureFocusModeAutoFocus exposeWithMode:AVCaptureExposureModeAutoExpose atDevicePoint:devicePoint monitorSubjectAreaChange:YES];
}

- (void)subjectAreaDidChange:(NSNotification *)notification {
	CGPoint devicePoint = CGPointMake(.5, .5);
	[self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
}

#pragma mark Device Configuration

- (void)focusWithMode:(AVCaptureFocusMode)focusMode exposeWithMode:(AVCaptureExposureMode)exposureMode atDevicePoint:(CGPoint)point monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange {
	dispatch_async([self sessionQueue], ^{
		AVCaptureDevice *device = [[self videoDeviceInput] device];
		NSError *error = nil;
		if ([device lockForConfiguration:&error])
		{
			if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:focusMode])
			{
				[device setFocusMode:focusMode];
				[device setFocusPointOfInterest:point];
			}
			if ([device isExposurePointOfInterestSupported] && [device isExposureModeSupported:exposureMode])
			{
				[device setExposureMode:exposureMode];
				[device setExposurePointOfInterest:point];
			}
			[device setSubjectAreaChangeMonitoringEnabled:monitorSubjectAreaChange];
			[device unlockForConfiguration];
		}
		else
		{
			NSLog(@"%@", error);
		}
	});
}

+ (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device {
	if ([device hasFlash] && [device isFlashModeSupported:flashMode])
	{
		NSError *error = nil;
		if ([device lockForConfiguration:&error])
		{
			[device setFlashMode:flashMode];
			[device unlockForConfiguration];
		}
		else
		{
			NSLog(@"%@", error);
		}
	}
}

+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position {
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
	AVCaptureDevice *captureDevice = [devices firstObject];
	
	for (AVCaptureDevice *device in devices)
	{
		if ([device position] == position)
		{
			captureDevice = device;
			break;
		}
	}
	
	return captureDevice;
}

#pragma mark UI

- (void)runStillImageCaptureAnimation {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[[self previewView] layer] setOpacity:0.0];
		[UIView animateWithDuration:1 animations:^{
			[[[self previewView] layer] setOpacity:1.0];
		}];
	});
}

- (void)checkDeviceAuthorizationStatus {
	NSString *mediaType = AVMediaTypeVideo;
	
	[AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
		if (granted)
		{
			//Granted access to mediaType
			[self setDeviceAuthorized:YES];
		}
		else
		{
			//Not granted access to mediaType
			dispatch_async(dispatch_get_main_queue(), ^{
				[[[UIAlertView alloc] initWithTitle:@"Shots!"
											message:@"Shots doesn't have permission to use Camera, please change privacy settings"
										   delegate:self
								  cancelButtonTitle:@"OK"
								  otherButtonTitles:nil] show];
				[self setDeviceAuthorized:NO];
			});
		}
	}];
}

#pragma mark - Image Orientation

- (UIImage *)fixOrientationOfImage:(UIImage *)image {
    
    // No-op if the orientation is already correct
    if (image.imageOrientation == UIImageOrientationUp) {
        UIImage* flippedImage = [UIImage imageWithCGImage:image.CGImage
                                                    scale:image.scale orientation:UIImageOrientationUpMirrored];
        return flippedImage;
    }
    
    // We need to calculate the proper transformation to make the image upright.
    // We do it in 2 steps: Rotate if Left/Right/Down, and then flip if Mirrored.
    CGAffineTransform transform = CGAffineTransformIdentity;
    
    switch (image.imageOrientation) {
        case UIImageOrientationDown:
        case UIImageOrientationDownMirrored:
            transform = CGAffineTransformTranslate(transform, image.size.width, image.size.height);
            transform = CGAffineTransformRotate(transform, M_PI);
            break;
            
        case UIImageOrientationLeft:
        case UIImageOrientationLeftMirrored:
            transform = CGAffineTransformTranslate(transform, image.size.width, 0);
            transform = CGAffineTransformRotate(transform, M_PI_2);
            break;
            
        case UIImageOrientationRight:
        case UIImageOrientationRightMirrored:
            transform = CGAffineTransformTranslate(transform, 0, image.size.height);
            transform = CGAffineTransformRotate(transform, -M_PI_2);
            break;
        case UIImageOrientationUp:
        case UIImageOrientationUpMirrored:
            break;
    }
    
    switch (image.imageOrientation) {
        case UIImageOrientationUpMirrored:
        case UIImageOrientationDownMirrored:
            transform = CGAffineTransformTranslate(transform, image.size.width, 0);
            transform = CGAffineTransformScale(transform, -1, 1);
            break;
            
        case UIImageOrientationLeftMirrored:
        case UIImageOrientationRightMirrored:
            transform = CGAffineTransformTranslate(transform, image.size.height, 0);
            transform = CGAffineTransformScale(transform, -1, 1);
            break;
        case UIImageOrientationUp:
        case UIImageOrientationDown:
        case UIImageOrientationLeft:
        case UIImageOrientationRight:
            break;
    }
    
    // Now we draw the underlying CGImage into a new context, applying the transform
    // calculated above.
    CGContextRef ctx = CGBitmapContextCreate(NULL, image.size.width, image.size.height,
                                             CGImageGetBitsPerComponent(image.CGImage), 0,
                                             CGImageGetColorSpace(image.CGImage),
                                             CGImageGetBitmapInfo(image.CGImage));
    CGContextConcatCTM(ctx, transform);
    switch (image.imageOrientation) {
        case UIImageOrientationLeft:
        case UIImageOrientationLeftMirrored:
        case UIImageOrientationRight:
        case UIImageOrientationRightMirrored:
            // Grr...
            CGContextDrawImage(ctx, CGRectMake(0,0,image.size.height,image.size.width), image.CGImage);
            break;
            
        default:
            CGContextDrawImage(ctx, CGRectMake(0,0,image.size.width,image.size.height), image.CGImage);
            break;
    }
    
    // And now we just create a new UIImage from the drawing context
    CGImageRef cgimg = CGBitmapContextCreateImage(ctx);
    UIImage *img = [UIImage imageWithCGImage:cgimg];
    CGContextRelease(ctx);
    CGImageRelease(cgimg);
    UIImage* flippedImage = [UIImage imageWithCGImage:img.CGImage
                                                scale:img.scale orientation:UIImageOrientationUpMirrored];
    return flippedImage;
}

@end
