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

#define ImageCapacity 24
#define SnapInterval 0.6 // SnapInterval > 0.6 will cancel the shutter sounds

static void * CapturingStillImageContext = &CapturingStillImageContext;
static void * SessionRunningAndDeviceAuthorizedContext = &SessionRunningAndDeviceAuthorizedContext;
static SystemSoundID soundID = 0;
static int countDownNumber = 3;

@interface MSCamViewController ()

@property (strong, nonatomic) IBOutlet UIView *stillButtonView;
@property (strong, nonatomic) IBOutlet MSCamPreviewView *previewView;
@property (strong, nonatomic) IBOutlet UIView *placeholderView;

@property (strong, nonatomic) UILabel *countDownLabel;

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
@property (nonatomic, strong) NSMutableArray *positionArrays;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSTimer *countDownTimer;
@property (nonatomic) BOOL isUserTapped;
@property (nonatomic) AVCaptureDevicePosition currentPosition;

@property (nonatomic, strong) RBVolumeButtons *buttonStealer;

// Tutorial
@property (nonatomic, strong) IBOutlet UIView *tutorialBackgroundView;
@property (nonatomic, strong) IBOutlet UIImageView *tutorialImageView;
@property (nonatomic) BOOL tutorialSwipeCompleted;
@property (nonatomic) BOOL tutorialPressAndHoldCompleted;

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

    NSString *appDomain = [[NSBundle mainBundle] bundleIdentifier];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:appDomain];
    
    self.countDownLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 100)];
    self.countDownLabel.center = self.view.center;
    self.countDownLabel.textAlignment = NSTextAlignmentCenter;
    self.countDownLabel.textColor = [UIColor whiteColor];
    self.countDownLabel.shadowColor = [UIColor blackColor];
    self.countDownLabel.shadowOffset = CGSizeMake(0, 3.0);
    self.countDownLabel.font = [UIFont systemFontOfSize:120];
    self.countDownLabel.hidden = YES;
    [self.previewView addSubview:self.countDownLabel];
    
    self.navigationController.navigationBar.hidden = YES;
    self.imageArrays = [NSMutableArray arrayWithCapacity:ImageCapacity];
    self.positionArrays = [NSMutableArray arrayWithCapacity:ImageCapacity];
    
    [self orientationChanged];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationChanged)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    
	// Create the AVCaptureSession
	AVCaptureSession *session = [[AVCaptureSession alloc] init];
	[self setSession:session];
	
	// Setup the preview view
//    [[self previewView] setup];
	[[self previewView] setSession:session];
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(focusAndExposeTap:)];
    [[self previewView] addGestureRecognizer:tapGesture];
    
    UISwipeGestureRecognizer *swipeUpGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(flipView:)];
    swipeUpGesture.direction = UISwipeGestureRecognizerDirectionUp;
    [[self previewView] addGestureRecognizer:swipeUpGesture];
    
    UISwipeGestureRecognizer *swipeDownGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(flipView:)];
    swipeDownGesture.direction = UISwipeGestureRecognizerDirectionDown;
    [[self previewView] addGestureRecognizer:swipeDownGesture];
    
    UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPressGesture.minimumPressDuration = 0.1;
    longPressGesture.allowableMovement = 20;
    [[self previewView] addGestureRecognizer:longPressGesture];
    
    [swipeUpGesture requireGestureRecognizerToFail:longPressGesture];
    [swipeDownGesture requireGestureRecognizerToFail:longPressGesture];
    
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
        self.currentPosition = [videoDevice position];
		
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
    
    [self showTutorial];
    
    [[Mixpanel sharedInstance] track:@"OPENED_CAMERA"];
}

- (void)viewWillAppear:(BOOL)animated {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becomeInactive) name:@"WILL_RESIGN_ACTIVE" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becomeActiveFromBackground) name:@"DID_BECOME_ACTIVE" object:nil];
    
    [self createShutterSound];

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
    [self stopCountDownTimer];
    [self.imageArrays removeAllObjects];
    [self.positionArrays removeAllObjects];
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

- (void)startCountDownTimer {
    countDownNumber = 3;
    [self countDownAnimation];
    self.countDownTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(countDownAnimation) userInfo:nil repeats:YES];
}

- (void)stopCountDownTimer {
    [self.countDownTimer invalidate];
    self.countDownTimer = nil;
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
	else if (context != SessionRunningAndDeviceAuthorizedContext)
	{
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

#pragma mark IBActions

- (IBAction)cameraButtonPressed:(id)sender {
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
		
        self.currentPosition = preferredPosition;
		AVCaptureDevice *videoDevice = [MSCamViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:preferredPosition];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];
		
		[[self session] beginConfiguration];
		
		[[self session] removeInput:[self videoDeviceInput]];
		if ([[self session] canAddInput:videoDeviceInput])
		{
			[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];
			
			[MSCamViewController setFlashMode:AVCaptureFlashModeOff forDevice:videoDevice];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:videoDevice];
			
			[[self session] addInput:videoDeviceInput];
			[self setVideoDeviceInput:videoDeviceInput];
		}
		else
		{
			[[self session] addInput:[self videoDeviceInput]];
		}
		
		[[self session] commitConfiguration];
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
    [self stopTimer];
    [self stopCountDownTimer];
    [self snapStillImage];
    [self setTutorialPressAndHoldComplete];
}

- (void)snapStillImage {
    dispatch_async([self sessionQueue], ^{
		// Update the orientation on the still image output video connection before capturing.
		[[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
		
		// Flash set to Off for Still Capture
        [MSCamViewController setFlashMode:AVCaptureFlashModeOff forDevice:[[self videoDeviceInput] device]];

        if (!self.isUserTapped) {
            AudioServicesPlaySystemSound(soundID);
        } else {
            AudioServicesDisposeSystemSoundID(soundID);
            soundID = 0;
            [MSCamViewController setFlashMode:AVCaptureFlashModeAuto forDevice:[[self videoDeviceInput] device]];
        }
        
		// Capture a still image.
		[[self stillImageOutput] captureStillImageAsynchronouslyFromConnection:[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
			
			if (imageDataSampleBuffer)
			{
				NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
				UIImage *image = [[UIImage alloc] initWithData:imageData];
                [self.imageArrays insertObject:image atIndex:0];
                [self.positionArrays insertObject:@(self.currentPosition) atIndex:0];
                if (self.imageArrays.count > ImageCapacity) {
                    UIImage *lastImage = [self.imageArrays lastObject];
                    [self.imageArrays removeLastObject];
                    lastImage = nil;
                    [self.positionArrays removeLastObject];
                }
                
                if (self.isUserTapped) {
                    MSPreviewViewController *previewVC = [self.storyboard instantiateViewControllerWithIdentifier:@"MSPreviewViewController"];
                    for (int i = 0; i < self.imageArrays.count; i++) {
                        UIImage *image = (UIImage *)self.imageArrays[i];
                        BOOL needsExtraFlip = [self.positionArrays[i] intValue] == AVCaptureDevicePositionFront;
                        UIImage *orientedImage = [self fixOrientationOfImage:image withExtraFlip:needsExtraFlip];
                        [self.imageArrays replaceObjectAtIndex:i withObject:orientedImage];
                    }
                    [previewVC setPhotos:self.imageArrays];
                    [previewVC setPositions:self.positionArrays];
                    __weak __typeof(self) weakSelf = self;
                    [self.navigationController presentViewController:previewVC animated:NO completion:^{
                        [weakSelf.imageArrays removeAllObjects];
                        [weakSelf.positionArrays removeAllObjects];
                    }];
                }
//                // TODO: remove
//				[[[ALAssetsLibrary alloc] init] writeImageToSavedPhotosAlbum:[image CGImage] orientation:(ALAssetOrientation)[image imageOrientation] completionBlock:nil];
			}
		}];
	});
}

#pragma mark - Gestures

- (IBAction)focusAndExposeTap:(UIGestureRecognizer *)gestureRecognizer {
	CGPoint devicePoint = [(AVCaptureVideoPreviewLayer *)[[self previewView] layer] captureDevicePointOfInterestForPoint:[gestureRecognizer locationInView:[gestureRecognizer view]]];
	[self focusWithMode:AVCaptureFocusModeAutoFocus exposeWithMode:AVCaptureExposureModeAutoExpose atDevicePoint:devicePoint monitorSubjectAreaChange:YES];
}

- (IBAction)flipView:(UISwipeGestureRecognizer *)gestureRecognizer {
    [self setLockInterfaceRotation:YES];
    self.previewView.frame = self.view.frame;
    self.placeholderView.frame = self.view.frame;
    
    void(^completionBlock)(void) = ^void(void) {
        [UIView transitionFromView:self.placeholderView
                            toView:self.previewView
                          duration:0.0
                           options:UIViewAnimationOptionTransitionFlipFromTop
                        completion:^(BOOL finished) {
                            [self setLockInterfaceRotation:NO];
                            self.previewView.frame = self.view.frame;
                            self.placeholderView.frame = self.view.frame;
                        }];
    };
    
    if (gestureRecognizer.direction == UISwipeGestureRecognizerDirectionUp) {
        [self cameraButtonPressed:self];
        [UIView transitionFromView:self.previewView
                            toView:self.placeholderView
                          duration:0.5
                           options:UIViewAnimationOptionTransitionFlipFromTop
                        completion:^(BOOL finished) {
                            completionBlock();
                        }];
        
    } else if (gestureRecognizer.direction == UISwipeGestureRecognizerDirectionDown) {
        [self cameraButtonPressed:self];
        [UIView transitionFromView:self.previewView
                            toView:self.placeholderView
                          duration:0.5
                           options:UIViewAnimationOptionTransitionFlipFromBottom
                        completion:^(BOOL finished) {
                            completionBlock();
                        }];
    }
    
    [self setTutorialSwipeComplete];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        CGPoint touchLocation = [gestureRecognizer locationInView:self.view];
        if (touchLocation.y > self.view.frame.size.height / 2) {
            // bottom part;
            self.countDownLabel.center = CGPointMake(touchLocation.x, touchLocation.y - 100);
        } else {
            // upper part
            self.countDownLabel.center = CGPointMake(touchLocation.x, touchLocation.y + 120);
        }
        [self startCountDownTimer];
        [self hideTutorialImageView];
    } else if (gestureRecognizer.state == UIGestureRecognizerStateEnded || gestureRecognizer.state == UIGestureRecognizerStateCancelled) {
        [self.countDownLabel.layer removeAllAnimations];
        [self stopCountDownTimer];
        [self showTutorialImageView];
    }
}

- (void)countDownAnimation {
    self.countDownLabel.hidden = NO;
    self.countDownLabel.text = [NSString stringWithFormat:@"%d", countDownNumber];
    if (countDownNumber < 1) {
        return;
    }
    self.countDownLabel.transform = CGAffineTransformMakeScale(0.2, 0.2);
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:10
                        options:0
                     animations:^{
                         self.countDownLabel.alpha = 0.5;
                         self.countDownLabel.alpha = 1.0;
                         self.countDownLabel.transform = CGAffineTransformMakeScale(1.0, 1.0);}
                     completion:^(BOOL finished) {
                         [UIView animateWithDuration:0.1 animations:^{
                             self.countDownLabel.alpha = 0.0;
                             self.countDownLabel.alpha = 0.0;
                             self.countDownLabel.transform = CGAffineTransformMakeScale(0.2, 0.2);
                         } completion:^(BOOL finished) {
                             countDownNumber--;
                             if (countDownNumber < 1) {
                                 self.countDownLabel.hidden = YES;
                                 [self stillButtonPressed:self];
                             }
                         }];
                     }];
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
        [[self placeholderView] setHidden:YES];
		[UIView animateWithDuration:1 animations:^{
			[[[self previewView] layer] setOpacity:1.0];
		} completion:^(BOOL finished) {
            [[self placeholderView] setHidden:NO];
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

- (UIImage *)fixOrientationOfImage:(UIImage *)image withExtraFlip:(BOOL)needsExtraFlip{
    
    // No-op if the orientation is already correct
    if (image.imageOrientation == UIImageOrientationUp) {
        if (needsExtraFlip) {
            UIImage* flippedImage = [UIImage imageWithCGImage:image.CGImage
                                                        scale:image.scale orientation:UIImageOrientationUpMirrored];
            return flippedImage;
        } else {
            return image;
        }
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
    if (needsExtraFlip) {
        UIImage* flippedImage = [UIImage imageWithCGImage:img.CGImage
                                                    scale:img.scale orientation:UIImageOrientationUpMirrored];
        return flippedImage;
    }
    else {
        return img;
    }
}

#pragma mark - Tutorial

- (void)showTutorial {
    self.tutorialSwipeCompleted = YES;
    self.tutorialPressAndHoldCompleted = YES;
    
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        self.tutorialSwipeCompleted = [[NSUserDefaults standardUserDefaults] boolForKey:@"tutorial-swipe"];
        self.tutorialPressAndHoldCompleted = [[NSUserDefaults standardUserDefaults] boolForKey:@"tutorial-press-and-hold"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.tutorialSwipeCompleted) {
                self.tutorialImageView.image = [UIImage imageNamed:@"tutorial_swipe.png"];
                self.tutorialBackgroundView.hidden = NO;
            } else if (!self.tutorialPressAndHoldCompleted) {
                self.tutorialImageView.image = [UIImage imageNamed:@"tutorial_press_and_hold.png"];
                self.tutorialBackgroundView.hidden = NO;
            } else {
                self.tutorialBackgroundView.hidden = YES;
            }
        });
    });
}

- (void)setTutorialSwipeComplete {
    if (self.tutorialSwipeCompleted == YES) {
        return;
    }
    
    self.tutorialSwipeCompleted = YES;
    
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        [[NSUserDefaults standardUserDefaults] setObject:[[NSNumber alloc] initWithBool:YES] forKey:@"tutorial-swipe"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showTutorial];
        });
    });
}

- (void)setTutorialPressAndHoldComplete {
    if (self.tutorialPressAndHoldCompleted == YES) {
        return;
    }
    
    self.tutorialPressAndHoldCompleted = YES;
    
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        [[NSUserDefaults standardUserDefaults] setObject:[[NSNumber alloc] initWithBool:YES] forKey:@"tutorial-press-and-hold"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showTutorial];
        });
    });
    
    [self showTutorial];
}

- (void)hideTutorialImageView {
    if (self.tutorialPressAndHoldCompleted == YES) {
        return;
    }
    
    self.tutorialBackgroundView.hidden = YES;
}

- (void)showTutorialImageView {
    if (self.tutorialPressAndHoldCompleted == YES) {
        return;
    }
    
    self.tutorialBackgroundView.hidden = NO;
}

@end
