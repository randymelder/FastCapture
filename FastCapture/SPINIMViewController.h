//
//  SPINIMViewController.h
//  FastCapture
//
//  Created by randymelder on 5/6/14.
//  Copyright (c) 2014 RCM Software LLC. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface SPINIMViewController : UIViewController 
@property (strong, nonatomic) IBOutlet UIImageView *myImageView;
@property (strong, nonatomic) IBOutlet UIButton *recordButton;
@property (strong, nonatomic) IBOutlet UIImageView *playButtonImage;
@property (strong, nonatomic) IBOutlet UILabel *secondsLabel;
@property (strong, nonatomic) IBOutlet UIImageView *settingsImage;

- (IBAction)doStartButton:(id)sender;
- (IBAction)doStopButton:(id)sender;
@end
