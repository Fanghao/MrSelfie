//
//  MSPreviewViewController.m
//  MrSelfie
//
//  Created by Weixi Yen on 5/15/14.
//  Copyright (c) 2014 MSStorm8. All rights reserved.
//

#import "MSPreviewViewController.h"

@interface MSPreviewViewController ()

@property (nonatomic, strong) IBOutlet UIImageView *imageView;
@property (nonatomic) int currentIndex;

@end


@implementation MSPreviewViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.currentIndex = 0;
    [self showNextImage];
}

- (void)showNextImage {
    [self.imageView setImage:[self.photos objectAtIndex:self.currentIndex]];
    
    // reached the end of slideshow
    if (self.currentIndex == self.photos.count - 1) {
        self.currentIndex = 0;
        [self performSelector:@selector(showNextImage) withObject:nil afterDelay:3];
        return;
    }
    
    // default case, increment and show the next image
    self.currentIndex += 1;
    [self performSelector:@selector(showNextImage) withObject:nil afterDelay:0.250];
}

@end
