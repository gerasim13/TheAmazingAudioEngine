//
//  AEAudioFilePlayer.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 13/02/2012.
//
//  Contributions by Ryan King and Jeremy Huff of Hello World Engineering, Inc on 7/15/15.
//      Copyright (c) 2015 Hello World Engineering, Inc. All rights reserved.
//  Contributions by Ryan Holmes
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "AEAudioFilePlayer.h"
#import "AEUtilities.h"
#import <libkern/OSAtomic.h>
#import <stdatomic.h>

@interface AEAudioFilePlayer () {
    AudioFileID _audioFile;
    AudioStreamBasicDescription _fileDescription;
    AudioStreamBasicDescription _outputDescription;
    UInt32 _lengthInFrames;
    NSTimeInterval _regionDuration;
    NSTimeInterval _regionStartTime;
    atomic_int_fast32_t _playhead;
    atomic_int_fast32_t _playbackStoppedCallbackScheduled;
    atomic_bool _running;
    atomic_bool _loop;
    uint64_t _startTime;
    AEAudioRenderCallback _superRenderCallback;
}
@property (nonatomic, strong, readwrite) NSURL * url;
@property (nonatomic, weak) AEAudioController * audioController;
@end

@implementation AEAudioFilePlayer
@dynamic loop;

+ (instancetype)audioFilePlayerWithURL:(NSURL *)url error:(NSError **)error {
    return [[self alloc] initWithURL:url error:error];
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    if ( !(self = [super initWithComponentDescription:AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer)]) ) return nil;
    
    if ( ![self loadAudioFileWithURL:url error:error] ) {
        return nil;
    }
    
    _superRenderCallback = [super renderCallback];
    
    return self;
}

- (void)dealloc {
    if ( _audioFile ) {
        AudioFileClose(_audioFile);
    }
}

- (void)setupWithAudioController:(AEAudioController *)audioController {
    [super setupWithAudioController:audioController];
    
    Float64 priorOutputSampleRate = _outputDescription.mSampleRate;
    _outputDescription = audioController.audioDescription;
    
    double sampleRateScaleFactor = _outputDescription.mSampleRate / (priorOutputSampleRate ? priorOutputSampleRate : _fileDescription.mSampleRate);
    atomic_store_explicit(&_playhead, atomic_load_explicit(&_playhead, memory_order_acquire) * sampleRateScaleFactor, memory_order_release);
    self.audioController = audioController;
    
    // Set the file to play
    UInt32 size = sizeof(_audioFile);
    OSStatus result = AudioUnitSetProperty(self.audioUnit, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global, 0, &_audioFile, size);
    AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileIDs)");
    
    // Play the file region
    if ( self.channelIsPlaying ) {
        double outputToSourceSampleRateScale = _fileDescription.mSampleRate / _outputDescription.mSampleRate;
        [self schedulePlayRegionFromPosition:atomic_load_explicit(&_playhead, memory_order_acquire) * outputToSourceSampleRateScale];
        atomic_store_explicit(&_running, YES, memory_order_release);
    }
}

- (void)teardown {
    int32_t playbackStoppedCallbackScheduled = atomic_load_explicit(&_playbackStoppedCallbackScheduled, memory_order_acquire);
    if ( atomic_compare_exchange_weak(&_playbackStoppedCallbackScheduled, &playbackStoppedCallbackScheduled, 0) ) {
        // A playback stop callback was scheduled - we need to flush events from the message queue to clear it out
        [self.audioController.messageQueue processMainThreadMessages];
    }
    self.audioController = nil;
    [super teardown];
}

- (void)playAtTime:(uint64_t)time {
    _startTime = time;
    if ( !self.channelIsPlaying ) {
        self.channelIsPlaying = YES;
    }
}

- (BOOL)loop
{
    return atomic_load_explicit(&_loop, memory_order_acquire);
}

- (void)setLoop:(BOOL)loop
{
    atomic_store_explicit(&_loop, loop, memory_order_release);
}

- (NSTimeInterval)duration {
    return (double)_lengthInFrames / (double)_fileDescription.mSampleRate;
}

- (NSTimeInterval)currentTime {
    return (double)atomic_load_explicit(&_playhead, memory_order_acquire) / (_outputDescription.mSampleRate ? _outputDescription.mSampleRate : _fileDescription.mSampleRate);
}

- (void)setCurrentTime:(NSTimeInterval)currentTime {
    if ( _lengthInFrames == 0 ) return;

    double sampleRate = _fileDescription.mSampleRate;

    [self schedulePlayRegionFromPosition:(UInt32)(self.regionStartTime * sampleRate) + ((UInt32)((currentTime - self.regionStartTime) * sampleRate) % (UInt32)(self.regionDuration * sampleRate))];
}

- (void)setChannelIsPlaying:(BOOL)playing {
    BOOL wasPlaying = self.channelIsPlaying;
    [super setChannelIsPlaying:playing];
    
    if ( wasPlaying == playing ) return;
    
    atomic_store_explicit(&_running, playing, memory_order_release);
    if ( self.audioUnit ) {
        if ( playing ) {
            double outputToSourceSampleRateScale = _fileDescription.mSampleRate / _outputDescription.mSampleRate;
            [self schedulePlayRegionFromPosition:atomic_load_explicit(&_playhead, memory_order_acquire) * outputToSourceSampleRateScale];
        } else {
            AECheckOSStatus(AudioUnitReset(self.audioUnit, kAudioUnitScope_Global, 0), "AudioUnitReset");
        }
    }
}

- (NSTimeInterval)regionDuration {
    return _regionDuration;
}

- (void)setRegionDuration:(NSTimeInterval)regionDuration {
    if (regionDuration < 0) {
        regionDuration = 0;
    }
    _regionDuration = regionDuration;
    
    int32_t playhead = atomic_load_explicit(&_playhead, memory_order_acquire);
    if (playhead < self.regionStartTime || playhead >= self.regionStartTime + regionDuration) {
        playhead = self.regionStartTime * _fileDescription.mSampleRate;
    }

    [self schedulePlayRegionFromPosition:(UInt32)(_regionStartTime * _fileDescription.mSampleRate)];
}

- (NSTimeInterval)regionStartTime {
    return _regionStartTime;
}

- (void)setRegionStartTime:(NSTimeInterval)regionStartTime {
    if (regionStartTime < 0) {
        regionStartTime = 0;
    }
    if (regionStartTime > _lengthInFrames / _fileDescription.mSampleRate) {
        regionStartTime = _lengthInFrames / _fileDescription.mSampleRate;
    }
    _regionStartTime = regionStartTime;
    
    int32_t playhead = atomic_load_explicit(&_playhead, memory_order_acquire);
    if (playhead < regionStartTime || playhead >= regionStartTime + self.regionDuration) {
        playhead = self.regionStartTime * _fileDescription.mSampleRate;
    }

    [self schedulePlayRegionFromPosition:(UInt32)(_regionStartTime * _fileDescription.mSampleRate)];
}

UInt32 AEAudioFilePlayerGetPlayhead(__unsafe_unretained AEAudioFilePlayer * THIS) {
    return atomic_load_explicit(&THIS->_playhead, memory_order_acquire);
}

- (BOOL)loadAudioFileWithURL:(NSURL*)url error:(NSError**)error {
    OSStatus result;
    
    // Open the file
    result = AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, 0, &_audioFile);
    if ( !AECheckOSStatus(result, "AudioFileOpenURL") ) {
        if (error)
        {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't open the audio file", @"")}];
        }
        return NO;
    }
    
    // Get the file data format
    UInt32 size = sizeof(_fileDescription);
    result = AudioFileGetProperty(_audioFile, kAudioFilePropertyDataFormat, &size, &_fileDescription);
    if ( !AECheckOSStatus(result, "AudioFileGetProperty(kAudioFilePropertyDataFormat)") ) {
        if (error)
        {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
        }
        AudioFileClose(_audioFile);
        _audioFile = NULL;
        return NO;
    }
    
    // Determine length in frames (in original file's sample rate)
    AudioFilePacketTableInfo packetInfo;
    size = sizeof(packetInfo);
    result = AudioFileGetProperty(_audioFile, kAudioFilePropertyPacketTableInfo, &size, &packetInfo);
    if ( result != noErr ) {
        size = 0;
    }
    
    UInt64 fileLengthInFrames;
    if ( size > 0 ) {
        fileLengthInFrames = packetInfo.mNumberValidFrames;
    } else {
        UInt64 packetCount;
        size = sizeof(packetCount);
        result = AudioFileGetProperty(_audioFile, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount);
        if ( !AECheckOSStatus(result, "AudioFileGetProperty(kAudioFilePropertyAudioDataPacketCount)") ) {
            if (error)
            {
                *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                         userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
            }
            AudioFileClose(_audioFile);
            _audioFile = NULL;
            return NO;
        }
        fileLengthInFrames = packetCount * _fileDescription.mFramesPerPacket;
    }
    
    if ( fileLengthInFrames == 0 ) {
        if (error)
        {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-50
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"This audio file is empty", @"")}];
        }
        AudioFileClose(_audioFile);
        _audioFile = NULL;
        return NO;
    }
    
    _lengthInFrames = (UInt32)fileLengthInFrames;
    _regionStartTime = 0;
    _regionDuration = (double)_lengthInFrames / _fileDescription.mSampleRate;
    self.url = url;
    
    return YES;
}

- (void)schedulePlayRegionFromPosition:(UInt32)position {
    // Note: "position" is in frames, in the input file's sample rate
    
    AudioUnit audioUnit = self.audioUnit;
    if ( !audioUnit || !_audioFile ) {
        return;
    }
    
    double sourceToOutputSampleRateScale = _outputDescription.mSampleRate / _fileDescription.mSampleRate;
    atomic_store_explicit(&_playhead, position * sourceToOutputSampleRateScale, memory_order_release);
    
    // Reset the unit, to clear prior schedules
    AECheckOSStatus(AudioUnitReset(audioUnit, kAudioUnitScope_Global, 0), "AudioUnitReset");
    
    // Determine start time
    Float64 mainRegionStartTime = 0;

    // Make sure region is valid
    if (self.regionStartTime > self.duration) {
        _regionStartTime = self.duration;
    }
    if (self.regionStartTime + self.regionDuration > self.duration) {
        _regionDuration = self.duration - self.regionStartTime;
    }
    
    if ( position > self.regionStartTime ) {
        // Schedule the remaining part of the audio, from startFrame to the end (starting immediately, without the delay)
        UInt32 framesToPlay = self.regionDuration * _fileDescription.mSampleRate - (position - self.regionStartTime * _fileDescription.mSampleRate);
        ScheduledAudioFileRegion region = {
            .mTimeStamp = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = 0 },
            .mAudioFile = _audioFile,
            .mStartFrame = position,
            .mFramesToPlay = framesToPlay
        };
        OSStatus result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)");

        mainRegionStartTime = framesToPlay * sourceToOutputSampleRateScale;
    }
    
    // Set the main file region to play
    ScheduledAudioFileRegion region = {
        .mTimeStamp = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = mainRegionStartTime },
        .mAudioFile = _audioFile,
            // Always loop the unit, even if we're not actually looping, to avoid expensive rescheduling when switching loop mode.
            // We'll handle play completion in AEAudioFilePlayerRenderNotify
        .mStartFrame = _regionStartTime * _fileDescription.mSampleRate,
        .mLoopCount = (UInt32)-1,
        .mFramesToPlay = _regionDuration * _fileDescription.mSampleRate
    };
    OSStatus result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0, &region, sizeof(region));
    if ( !AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)") ) {
        NULL;
    }
    
    // Prime the player
    UInt32 primeFrames = 0;
    result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFilePrime, kAudioUnitScope_Global, 0, &primeFrames, sizeof(primeFrames));
    AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFilePrime)");
    
    // Set the start time
    AudioTimeStamp startTime = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = -1 /* ASAP */ };
    result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduleStartTimeStamp, kAudioUnitScope_Global, 0, &startTime, sizeof(startTime));
    AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduleStartTimeStamp)");
}

static OSStatus renderCallback(__unsafe_unretained AEAudioFilePlayer *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp       *time,
                               UInt32                      frames,
                               AudioBufferList            *audio) {
    
    if ( !atomic_load_explicit(&THIS->_running, memory_order_acquire) ) return noErr;
    
    uint64_t hostTimeAtBufferEnd = time->mHostTime + AEHostTicksFromSeconds((double)frames / THIS->_outputDescription.mSampleRate);
    if ( THIS->_startTime && THIS->_startTime > hostTimeAtBufferEnd ) {
        // Start time not yet reached: emit silence
        return noErr;
    }
    
    uint32_t silentFrames = THIS->_startTime && THIS->_startTime > time->mHostTime
        ? AESecondsFromHostTicks(THIS->_startTime - time->mHostTime) * THIS->_outputDescription.mSampleRate : 0;
    AEAudioBufferListCopyOnStack(scratchAudioBufferList, audio, silentFrames * THIS->_outputDescription.mBytesPerFrame);
    AudioTimeStamp adjustedTime = *time;
    
    if ( silentFrames > 0 ) {
        // Start time is offset into this buffer - silence beginning of buffer
        for ( int i=0; i<audio->mNumberBuffers; i++) {
            memset(audio->mBuffers[i].mData, 0, silentFrames * THIS->_outputDescription.mBytesPerFrame);
        }
        
        // Point buffer list to remaining frames
        audio = scratchAudioBufferList;
        frames -= silentFrames;
        adjustedTime.mHostTime = THIS->_startTime;
        adjustedTime.mSampleTime += silentFrames;
    }
    
    THIS->_startTime = 0;
    
    // Render
    THIS->_superRenderCallback(THIS, audioController, ioActionFlags, &adjustedTime, frames, audio);
    
    // Examine playhead
    int32_t playhead = atomic_load_explicit(&THIS->_playhead, memory_order_acquire);
    UInt32 regionLengthInFrames = ceil(THIS->_regionDuration * THIS->_outputDescription.mSampleRate);
    UInt32 regionStartTimeInFrames = ceil(THIS->_regionStartTime * THIS->_outputDescription.mSampleRate);
    
    if ( playhead - regionStartTimeInFrames + frames >= regionLengthInFrames &&
        !atomic_load_explicit(&THIS->_loop, memory_order_acquire) ) {
        // We just crossed the loop boundary; if not looping, end the track.
        UInt32 finalFrames = MIN(regionLengthInFrames - (playhead - regionStartTimeInFrames), frames);
        for ( int i=0; i<audio->mNumberBuffers; i++) {
            // Silence the rest of the buffer past the end
            memset((char*)audio->mBuffers[i].mData + (THIS->_outputDescription.mBytesPerFrame * finalFrames), 0, (THIS->_outputDescription.mBytesPerFrame * (frames - finalFrames)));
        }
        
        // Reset the unit, to cease playback
        AECheckOSStatus(AudioUnitReset(AEAudioUnitChannelGetAudioUnit(THIS), kAudioUnitScope_Global, 0), "AudioUnitReset");
        playhead = 0;
        
        // Schedule the playback ended callback (if it hasn't been scheduled already)
        int32_t playbackStoppedCallbackScheduled = atomic_load_explicit(&THIS->_playbackStoppedCallbackScheduled, memory_order_acquire);
        if ( atomic_compare_exchange_weak(&THIS->_playbackStoppedCallbackScheduled, &playbackStoppedCallbackScheduled, 1) ) {
            AEAudioControllerSendAsynchronousMessageToMainThread(THIS->_audioController, AEAudioFilePlayerNotifyCompletion, &THIS, sizeof(AEAudioFilePlayer*));
        }
    }
    
    // Update the playhead
    playhead = regionStartTimeInFrames + ((playhead - regionStartTimeInFrames + frames) % regionLengthInFrames);
    atomic_store_explicit(&THIS->_playhead, playhead, memory_order_release);
    
    return noErr;
}

-(AEAudioRenderCallback)renderCallback {
    return renderCallback;
}

static void AEAudioFilePlayerNotifyCompletion(void *userInfo, int userInfoLength) {
    AEAudioFilePlayer *THIS = (__bridge AEAudioFilePlayer*)*(void**)userInfo;
    atomic_store_explicit(&THIS->_running, NO, memory_order_release);
    
    int32_t playbackStoppedCallbackScheduled = atomic_load_explicit(&THIS->_playbackStoppedCallbackScheduled, memory_order_acquire);
    if ( !atomic_compare_exchange_weak(&THIS->_playbackStoppedCallbackScheduled, &playbackStoppedCallbackScheduled, 0) ) {
        // We've been pre-empted by another scheduled callback: bail for now
        return;
    }
    
    if ( THIS.removeUponFinish ) {
        [THIS.audioController removeChannels:@[THIS] completionBlock:nil];
    }
    THIS.channelIsPlaying = NO;
    if ( THIS.completionBlock ) {
        THIS.completionBlock();
    }
}

@end
