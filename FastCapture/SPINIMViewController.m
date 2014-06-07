//
//  SPINIMViewController.m
//  FastCapture
//
//  Created by randymelder on 5/6/14.
//  Copyright (c) 2014 RCM Software LLC. All rights reserved.
//

#import "SPINIMViewController.h"

#import "AVCamPreviewView.h"
#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <ImageIO/ImageIO.h>
#import <CoreMedia/CoreMedia.h>

#define DEFAULT_INTERVAL_SECONDS        10.0
#define COMMENT_BLOCK_MASTHEAD          @"\n===============================================================\n\
===============================================================\n\
===============================================================\n\
======================== %@ ==============================\n\
===============================================================\n\
===============================================================\n\
===============================================================\n"



static void * CapturingStillImageContext                = &CapturingStillImageContext;
static void * RecordingContext                          = &RecordingContext;
static void * SessionRunningAndDeviceAuthorizedContext  = &SessionRunningAndDeviceAuthorizedContext;

@interface SPINIMViewController() <AVCaptureFileOutputRecordingDelegate>

// For use in the storyboards.
@property (nonatomic, weak) IBOutlet AVCamPreviewView *previewView;
@property (nonatomic, weak) IBOutlet UIButton *cameraButton;
@property (nonatomic, weak) IBOutlet UIButton *stillButton;

- (IBAction)toggleMovieRecording:(id)sender;
- (IBAction)changeCamera:(id)sender;
- (IBAction)snapStillImage:(id)sender;
- (IBAction)focusAndExposeTap:(UIGestureRecognizer *)gestureRecognizer;

// Session management.
@property (nonatomic) dispatch_queue_t sessionQueue; // Communicate with the session and other session objects on this queue.
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (nonatomic) AVCaptureMovieFileOutput *movieFileOutput;
@property (nonatomic) AVCaptureStillImageOutput *stillImageOutput;
@property (nonatomic) NSTimer *myTimer;

// Utilities.
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID;
@property (nonatomic, getter = isDeviceAuthorized) BOOL deviceAuthorized;
@property (nonatomic, readonly, getter = isSessionRunningAndDeviceAuthorized) BOOL sessionRunningAndDeviceAuthorized;
@property (nonatomic) BOOL lockInterfaceRotation;
@property (nonatomic) BOOL proceedRecording;
@property (nonatomic) BOOL isRecording;
@property (nonatomic) id runtimeErrorHandlingObserver;

@end

@implementation SPINIMViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
    NSLog(@"%s", __FUNCTION__);
    self.proceedRecording   = NO;
    self.isRecording        = NO;
    
    self.playButtonImage.transform  = CGAffineTransformMakeRotation(M_PI_2);
    self.secondsLabel.transform     = CGAffineTransformMakeRotation(M_PI_2);
    
    // Create the AVCaptureSession
	AVCaptureSession *session = [[AVCaptureSession alloc] init];
	[self setSession:session];
	
	// Setup the preview view
	[[self previewView] setSession:session];
	
	// Check for device authorization
	[self checkDeviceAuthorizationStatus];
	
	// In general it is not safe to mutate an AVCaptureSession or any of its inputs, outputs, or connections from multiple threads at the same time.
	// Why not do all of this on the main queue?
	// -[AVCaptureSession startRunning] is a blocking call which can take a long time. We dispatch session setup to the sessionQueue so that the main queue isn't blocked (which keeps the UI responsive).
	
	dispatch_queue_t sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
	[self setSessionQueue:sessionQueue];
	
	dispatch_async(sessionQueue, ^{
		/////////////////////////////////////////
        // Video Input
        /////////////////////////////////////////
		[self setBackgroundRecordingID:UIBackgroundTaskInvalid];
		NSError *error = nil;
		AVCaptureDevice *videoDevice = [SPINIMViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:AVCaptureDevicePositionBack];
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
				// Because AVCaptureVideoPreviewLayer is the backing layer for AVCamPreviewView and UIView can only be manipulated on main thread.
				// Note: As an exception to the above rule, it is not necessary to serialize video orientation changes on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
                
				[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection]
                 setVideoOrientation:(AVCaptureVideoOrientation)[self interfaceOrientation]];
			});
		}
		
		AVCaptureDevice *audioDevice = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio] firstObject];
		AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
		
		if (error)
		{
			NSLog(@"%@", error);
		}
		
        
        /////////////////////////////////////////
        // Audio Input
        /////////////////////////////////////////
		if ([session canAddInput:audioDeviceInput])
		{
			[session addInput:audioDeviceInput];
		}
		
        
        /////////////////////////////////////////
        // Video Output
        /////////////////////////////////////////
		AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
		if ([session canAddOutput:movieFileOutput])
		{
			[session addOutput:movieFileOutput];
			AVCaptureConnection *connection = [movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
			if ([connection isVideoStabilizationSupported])
				[connection setEnablesVideoStabilizationWhenAvailable:YES];
			[self setMovieFileOutput:movieFileOutput];
		}
		
        /////////////////////////////////////////
        // Still Camera
        /////////////////////////////////////////
		AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
		if ([session canAddOutput:stillImageOutput])
		{
			[stillImageOutput setOutputSettings:@{AVVideoCodecKey : AVVideoCodecJPEG}];
			[session addOutput:stillImageOutput];
			[self setStillImageOutput:stillImageOutput];
		}
	});

}

- (void) viewWillAppear:(BOOL)animated {
    dispatch_async([self sessionQueue], ^{
		[self addObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:SessionRunningAndDeviceAuthorizedContext];
		[self addObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:CapturingStillImageContext];
		[self addObserver:self forKeyPath:@"movieFileOutput.recording" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:RecordingContext];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
		
		__weak SPINIMViewController *weakSelf = self;
		[self setRuntimeErrorHandlingObserver:[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self.session queue:nil usingBlock:^(NSNotification *note) {
			SPINIMViewController *strongSelf = weakSelf;
			dispatch_async([strongSelf sessionQueue], ^{
				// Manually restarting the session since it must have been stopped due to an error.
				[[strongSelf session] startRunning];
				[[strongSelf recordButton] setTitle:NSLocalizedString(@"Record", @"Recording button record title") forState:UIControlStateNormal];
			});
		}]];
		[self.session startRunning];
	});
}

- (void)didReceiveMemoryWarning
{
    NSLog(@"%s", __FUNCTION__);
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)viewDidDisappear:(BOOL)animated
{
    NSLog(@"%s", __FUNCTION__);
	dispatch_async([self sessionQueue], ^{
		[self.session stopRunning];
		
		[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
		[[NSNotificationCenter defaultCenter] removeObserver:[self runtimeErrorHandlingObserver]];
		
		[self removeObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" context:SessionRunningAndDeviceAuthorizedContext];
		[self removeObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" context:CapturingStillImageContext];
		[self removeObserver:self forKeyPath:@"movieFileOutput.recording" context:RecordingContext];
	});
}

- (BOOL)prefersStatusBarHidden
{
    NSLog(@"%s", __FUNCTION__);
	return YES;
}

- (BOOL)shouldAutorotate
{
    NSLog(@"%s", __FUNCTION__);
	// Disable autorotation of the interface when recording is in progress.
	return ![self lockInterfaceRotation];
}

- (NSUInteger)supportedInterfaceOrientations
{
    NSLog(@"%s", __FUNCTION__);
	return UIInterfaceOrientationMaskAll;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    NSLog(@"%s", __FUNCTION__);
	[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)toInterfaceOrientation];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    NSLog(@"%s", __FUNCTION__);
	if (context == CapturingStillImageContext)
	{
		BOOL isCapturingStillImage = [change[NSKeyValueChangeNewKey] boolValue];
		
		if (isCapturingStillImage)
		{
			[self runStillImageCaptureAnimation];
		}
	}
	else if (context == RecordingContext)
	{
		BOOL isRecording = [change[NSKeyValueChangeNewKey] boolValue];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			if (isRecording)
			{
				//[[self cameraButton] setEnabled:NO];
				[[self recordButton] setTitle:NSLocalizedString(@"Stop", @"Recording button stop title") forState:UIControlStateNormal];
				//[[self recordButton] setEnabled:YES];
			}
			else
			{
				//[[self cameraButton] setEnabled:YES];
				[[self recordButton] setTitle:NSLocalizedString(@"Record", @"Recording button record title") forState:UIControlStateNormal];
				//[[self recordButton] setEnabled:YES];
			}
		});
	}
	else if (context == SessionRunningAndDeviceAuthorizedContext)
	{
		BOOL isRunning = [change[NSKeyValueChangeNewKey] boolValue];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			if (isRunning)
			{
				//[[self cameraButton] setEnabled:YES];
				[[self recordButton] setEnabled:YES];
				//[[self stillButton] setEnabled:YES];
			}
			else
			{
				//[[self cameraButton] setEnabled:NO];
				[[self recordButton] setEnabled:NO];
				//[[self stillButton] setEnabled:NO];
			}
		});
	}
	else
	{
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}


#pragma mark - UI IBActions

- (void) touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    
    switch (touch.view.tag) {
        case 100:       // PlayPause button
            [self doToggleRecordPause];
            break;
        case 110:       // Settings
            [self doSettingsButton];
            break;
        default:
            break;
    }
    
}

- (void) doToggleRecordPause {
    if (self.isRecording) {
        self.isRecording = NO;
        [self doStopButton:self];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.playButtonImage.image = [UIImage imageNamed:@"play_button.png"];
        });
    } else {
        if (![self doTestVideoCapable]) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Error" message:@"Video not available on this device." delegate:Nil cancelButtonTitle:@"OK" otherButtonTitles: nil];
            [alert show];
            return;
        }
        self.isRecording = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.playButtonImage.image = [UIImage imageNamed:@"pause_button.png"];
        });
        [self doStartButton:self];
    }
}

- (BOOL) doTestVideoCapable {
    NSString *model = [[UIDevice currentDevice] model];
    NSLog(@"%s %@", __FUNCTION__, model);
    if ([model isEqualToString:@"iPhone Simulator"]) {
        return NO;
    }
    
    
    
    return YES;
}

- (IBAction)doStartButton:(id)sender {
    NSLog(@"%s", __FUNCTION__);
    
    self.recordButton.enabled = NO;
    //[self loopVideo:sender];
    self.proceedRecording = YES;
    
    if (![self.session isRunning]) {
        [self.session startRunning];
    }
    
    self.myTimer = [NSTimer scheduledTimerWithTimeInterval:DEFAULT_INTERVAL_SECONDS + 1.0
                                                    target:self
                                                  selector:@selector(loopVideo:)
                                                  userInfo:nil
                                                   repeats:YES];
    
    
    NSLog(COMMENT_BLOCK_MASTHEAD, @"STARTED");
    
}

- (IBAction)doStopButton:(id)sender {
    NSLog(@"%s", __FUNCTION__);
    
    self.recordButton.enabled = YES;
    self.proceedRecording = NO;
    [self doStopRecordingVideo];
    
    dispatch_async([self sessionQueue], ^{
        
		[self.session stopRunning];
        if (nil != self.myTimer) {
            [self.myTimer invalidate];
            self.myTimer = nil;
            
            NSLog(COMMENT_BLOCK_MASTHEAD, @"STOPPED");
        }
    });
    
    NSLog(@"%s\nself.myTimer == %@", __FUNCTION__, self.myTimer);
}

- (void) doSettingsButton {
    NSLog(@"%s", __FUNCTION__);
    if (self.isRecording) {
        [self doToggleRecordPause];
    }
    
    [self performSegueWithIdentifier:@"settingsSegue" sender:self];
    
}

#pragma mark - Actions
- (void) loopVideo:(id) sender {
    NSLog(@"%s", __FUNCTION__);
    
    if (NO == self.proceedRecording) {
        NSLog(@"%s\nNO == self.proceedRecording", __FUNCTION__);
        NSLog(@"%s\n%@ == self.myTimer", __FUNCTION__, self.myTimer);
        return;
    }
    
    NSLog(COMMENT_BLOCK_MASTHEAD, @"LOOPING");
    
    [self doStartRecordingVideo];
    int64_t delayInSeconds = DEFAULT_INTERVAL_SECONDS;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self doStopRecordingVideo];
    });
}

- (void) doStartRecordingVideo
{
    NSLog(@"%s", __FUNCTION__);
    
    if (NO == self.proceedRecording) {
        return;
    }
	
	dispatch_async([self sessionQueue], ^{
		[self setLockInterfaceRotation:YES];
			
        if ([[UIDevice currentDevice] isMultitaskingSupported])
        {
            // Setup background task. This is needed because the captureOutput:didFinishRecordingToOutputFileAtURL: callback is not received until AVCam returns to the foreground unless you request background execution time. This also ensures that there will be time to write the file to the assets library when AVCam is backgrounded. To conclude this background execution, -endBackgroundTask is called in -recorder:recordingDidFinishToOutputFileURL:error: after the recorded file has been saved.
            [self setBackgroundRecordingID:[[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil]];
        }
        
        // Update the orientation on the movie file output video connection before starting recording.
        [[[self movieFileOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
        
        // Turning OFF flash for video recording
        [SPINIMViewController setFlashMode:AVCaptureFlashModeOff forDevice:[[self videoDeviceInput] device]];
        
        // Start recording to a temporary file.
        //NSString *outputFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"movie" stringByAppendingPathExtension:@"mov"]];
        NSString *guid = [[NSUUID new] UUIDString];
        NSString *outputFilePath = [NSString stringWithFormat:@"%@/%@.mov", NSTemporaryDirectory(), guid];
        NSLog(@"%s\n%@", __FUNCTION__, outputFilePath);
        [[self movieFileOutput] startRecordingToOutputFileURL:[NSURL fileURLWithPath:outputFilePath] recordingDelegate:self];
	});
}
- (void) doStopRecordingVideo
{
    NSLog(@"%s", __FUNCTION__);
    dispatch_async([self sessionQueue], ^{
		[[self movieFileOutput] stopRecording];
	});
}

- (IBAction)toggleMovieRecording:(id)sender
{
    NSLog(@"%s", __FUNCTION__);
	//[[self recordButton] setEnabled:NO];
	
	dispatch_async([self sessionQueue], ^{
		if (![[self movieFileOutput] isRecording])
		{
			[self setLockInterfaceRotation:YES];
			
			if ([[UIDevice currentDevice] isMultitaskingSupported])
			{
				// Setup background task. This is needed because the captureOutput:didFinishRecordingToOutputFileAtURL: callback is not received until AVCam returns to the foreground unless you request background execution time. This also ensures that there will be time to write the file to the assets library when AVCam is backgrounded. To conclude this background execution, -endBackgroundTask is called in -recorder:recordingDidFinishToOutputFileURL:error: after the recorded file has been saved.
				[self setBackgroundRecordingID:[[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil]];
			}
			
			// Update the orientation on the movie file output video connection before starting recording.
			[[[self movieFileOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
			
			// Turning OFF flash for video recording
			[SPINIMViewController setFlashMode:AVCaptureFlashModeOff forDevice:[[self videoDeviceInput] device]];
			
			// Start recording to a temporary file.
			//NSString *outputFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"movie" stringByAppendingPathExtension:@"mov"]];
            NSString *outputFilePath = [NSString stringWithFormat:@"%@/tmpvideo.mov", NSTemporaryDirectory()];
            NSLog(@"%s\n%@", __FUNCTION__, outputFilePath);
			[[self movieFileOutput] startRecordingToOutputFileURL:[NSURL fileURLWithPath:outputFilePath] recordingDelegate:self];
		}
		else
		{
			//[[self movieFileOutput] stopRecording];
            [self doStopButton:self];
		}
	});
}

- (IBAction)changeCamera:(id)sender
{
    NSLog(@"%s", __FUNCTION__);
	
	dispatch_async([self sessionQueue], ^{
		AVCaptureDevice *currentVideoDevice         = [[self videoDeviceInput] device];
		AVCaptureDevicePosition preferredPosition   = AVCaptureDevicePositionUnspecified;
		AVCaptureDevicePosition currentPosition     = [currentVideoDevice position];
		
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
		
		AVCaptureDevice *videoDevice                = [SPINIMViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:preferredPosition];
		AVCaptureDeviceInput *videoDeviceInput      = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];
		
		[self.session beginConfiguration];
        
        if ([self.session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
            self.session.sessionPreset = AVCaptureSessionPreset1280x720;
        }
        else {
            self.session.sessionPreset = AVCaptureSessionPresetHigh;
        }
		
		[self.session removeInput:[self videoDeviceInput]];
		if ([self.session canAddInput:videoDeviceInput])
		{
			[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];
			
			[SPINIMViewController setFlashMode:AVCaptureFlashModeAuto forDevice:videoDevice];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:videoDevice];
			
			[self.session addInput:videoDeviceInput];
			[self setVideoDeviceInput:videoDeviceInput];
		}
		else
		{
			[self.session addInput:[self videoDeviceInput]];
		}
		
		[self.session commitConfiguration];
		
		
	});
}

- (IBAction)snapStillImage:(id)sender
{
    NSLog(@"%s", __FUNCTION__);
	dispatch_async([self sessionQueue], ^{
		// Update the orientation on the still image output video connection before capturing.
		[[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
		
		// Flash set to Auto for Still Capture
		[SPINIMViewController setFlashMode:AVCaptureFlashModeAuto forDevice:[[self videoDeviceInput] device]];
		
		// Capture a still image.
		[[self stillImageOutput] captureStillImageAsynchronouslyFromConnection:[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
			
			if (imageDataSampleBuffer)
			{
				NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
				UIImage *image = [[UIImage alloc] initWithData:imageData];
				[[[ALAssetsLibrary alloc] init] writeImageToSavedPhotosAlbum:[image CGImage] orientation:(ALAssetOrientation)[image imageOrientation] completionBlock:nil];
			}
		}];
	});
}

- (IBAction)focusAndExposeTap:(UIGestureRecognizer *)gestureRecognizer
{
    NSLog(@"%s", __FUNCTION__);
	CGPoint devicePoint = [(AVCaptureVideoPreviewLayer *)[[self previewView] layer] captureDevicePointOfInterestForPoint:[gestureRecognizer locationInView:[gestureRecognizer view]]];
	[self focusWithMode:AVCaptureFocusModeAutoFocus exposeWithMode:AVCaptureExposureModeAutoExpose atDevicePoint:devicePoint monitorSubjectAreaChange:YES];
}

- (void)subjectAreaDidChange:(NSNotification *)notification
{
    NSLog(@"%s", __FUNCTION__);
	CGPoint devicePoint = CGPointMake(.5, .5);
	[self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
}

#pragma mark File Output Delegate

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    NSLog(@"%s", __FUNCTION__);
	if (error)
		NSLog(@"%@", error);
	
	[self setLockInterfaceRotation:NO];
	
	// Note the backgroundRecordingID for use in the ALAssetsLibrary completion handler to end the background task associated with this recording. This allows a new recording to be started, associated with a new UIBackgroundTaskIdentifier, once the movie file output's -isRecording is back to NO — which happens sometime after this method returns.
	UIBackgroundTaskIdentifier backgroundRecordingID = [self backgroundRecordingID];
	[self setBackgroundRecordingID:UIBackgroundTaskInvalid];
	
	[[[ALAssetsLibrary alloc] init] writeVideoAtPathToSavedPhotosAlbum:outputFileURL completionBlock:^(NSURL *assetURL, NSError *error) {
		if (error)
			NSLog(@"%@", error);
		
		[[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
		
		if (backgroundRecordingID != UIBackgroundTaskInvalid)
			[[UIApplication sharedApplication] endBackgroundTask:backgroundRecordingID];
	}];
}

#pragma mark Device Configuration

- (void)focusWithMode:(AVCaptureFocusMode)focusMode exposeWithMode:(AVCaptureExposureMode)exposureMode atDevicePoint:(CGPoint)point monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange
{
    NSLog(@"%s", __FUNCTION__);
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

+ (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device
{
    NSLog(@"%s", __FUNCTION__);
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

+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
    NSLog(@"%s", __FUNCTION__);
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

- (void)runStillImageCaptureAnimation
{
    NSLog(@"%s", __FUNCTION__);
	dispatch_async(dispatch_get_main_queue(), ^{
		[[[self previewView] layer] setOpacity:0.0];
		[UIView animateWithDuration:.25 animations:^{
			[[[self previewView] layer] setOpacity:1.0];
		}];
	});
}

- (void)checkDeviceAuthorizationStatus
{
    NSLog(@"%s", __FUNCTION__);
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
				[[[UIAlertView alloc] initWithTitle:@"AVCam!"
											message:@"AVCam doesn't have permission to use Camera, please change privacy settings"
										   delegate:self
								  cancelButtonTitle:@"OK"
								  otherButtonTitles:nil] show];
				[self setDeviceAuthorized:NO];
			});
		}
	}];
}

@end
