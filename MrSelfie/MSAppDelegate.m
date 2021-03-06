//
//  MSAppDelegate.m
//  MrSelfie
//
//  Created by Fanghao Chen on 5/15/14.
//  Copyright (c) 2014 MSStorm8. All rights reserved.
//

#import "MSAppDelegate.h"
#import "Mixpanel.h"

@interface MSAppDelegate()

@property (nonatomic) BOOL activatedFromBackground;

@end

@implementation MSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    [Mixpanel sharedInstanceWithToken:@"1ea44c33388225967058a90e79beb09e"];
    
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"HasLaunchedOnce"])
    {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"HasLaunchedOnce"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        [[Mixpanel sharedInstance] track:@"FIRST_TIME_LAUNCH"];
    }
    
    self.activatedFromBackground = NO;
    
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WILL_RESIGN_ACTIVE" object:nil];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    self.activatedFromBackground = YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    if (self.activatedFromBackground) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DID_BECOME_ACTIVE" object:nil];
    }
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

@end
