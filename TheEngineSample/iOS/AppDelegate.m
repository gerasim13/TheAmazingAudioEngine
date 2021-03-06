//
//  AppDelegate.m
//  Audio Controller Test Suite
//
//  Created by Michael Tyson on 13/02/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AppDelegate.h"
#import "ViewController.h"
#import "TheAmazingAudioEngine.h"

@implementation AppDelegate

@synthesize window = _window;
@synthesize viewController = _viewController;
@synthesize audioController = _audioController;


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    
    // Create an instance of the audio controller, set it up and start it running
    AEAudioControllerOptions options = AEAudioControllerOptionDefaults | AEAudioControllerOptionEnableInput | AEAudioControllerOptionMultiroutOutput;
    AudioStreamBasicDescription description = AEAudioStreamBasicDescriptionNonInterleavedFloatStereo;
    description.mChannelsPerFrame = 4;
    self.audioController = [[AEAudioController alloc] initWithAudioDescription:description options:options];
    _audioController.preferredBufferDuration = 0.005;
    _audioController.preferredOutputNumberOfChannels = 4;
    _audioController.useMeasurementMode = YES;
    [_audioController start:NULL];
    
    // Create and display view controller
    self.viewController = [[ViewController alloc] initWithAudioController:_audioController];
    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];
    
    return YES;
}

@end
