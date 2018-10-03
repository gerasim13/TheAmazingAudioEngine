//
//  AEBlockScheduler.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 22/03/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//

#import "AEBlockScheduler.h"
#import "AEUtilities.h"
#import <libkern/OSAtomic.h>
#import <stdatomic.h>
#import <mach/mach_time.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

const int kMaximumSchedules = 100;

NSString const * AEBlockSchedulerKeyBlock = @"block";
NSString const * AEBlockSchedulerKeyTimestampInHostTicks = @"time";
NSString const * AEBlockSchedulerKeyResponseBlock = @"response";
NSString const * AEBlockSchedulerKeyIdentifier = @"identifier";
NSString const * AEBlockSchedulerKeyTimingContext = @"context";

struct _schedule_t {
    void * _Atomic block;
    void * _Atomic responseBlock;
    void * _Atomic identifier;
    atomic_uint_fast64_t time;
    atomic_uint_fast32_t context; // AEAudioTimingContext
};

@interface AEBlockScheduler () {
    struct _schedule_t   _schedule[kMaximumSchedules];
    atomic_uint_fast32_t _head;
    atomic_uint_fast32_t _tail;
}
@property (nonatomic, strong) NSMutableArray *scheduledIdentifiers;
@property (nonatomic, weak) AEAudioController *audioController;
@end

@implementation AEBlockScheduler
@synthesize scheduledIdentifiers = _scheduledIdentifiers;

+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
    __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
}

+ (uint64_t)now {
    return mach_absolute_time();
}

+ (uint64_t)hostTicksFromSeconds:(NSTimeInterval)seconds {
    return seconds * __secondsToHostTicks;
}

+ (NSTimeInterval)secondsFromHostTicks:(uint64_t)ticks {
    return (double)ticks * __hostTicksToSeconds;
}

+ (uint64_t)timestampWithSecondsFromNow:(NSTimeInterval)seconds {
    return mach_absolute_time() + (seconds * __secondsToHostTicks);
}

+ (NSTimeInterval)secondsUntilTimestamp:(uint64_t)timestamp {
    return (int64_t)(timestamp - mach_absolute_time()) * __hostTicksToSeconds;
}

+ (uint64_t)timestampWithSeconds:(NSTimeInterval)seconds fromTimestamp:(uint64_t)timeStamp
{
    return (timeStamp + (seconds * __secondsToHostTicks));
}

- (id)initWithAudioController:(AEAudioController *)audioController {
    if ( !(self = [super init]) ) return nil;
    
    self.audioController = audioController;
    self.scheduledIdentifiers = [NSMutableArray array];
    
    return self;
}

-(void)dealloc {
    for ( int i=0; i<kMaximumSchedules; i++ ) {
        if ( _schedule[i].block ) {
            CFBridgingRelease(_schedule[i].block);
            if ( _schedule[i].responseBlock ) {
                CFBridgingRelease(_schedule[i].responseBlock);
            }
            CFBridgingRelease(_schedule[i].identifier);
        }
    }
    self.audioController = nil;
}

-(void)scheduleBlock:(AEBlockSchedulerBlock)block atTime:(uint64_t)time timingContext:(AEAudioTimingContext)context identifier:(id<NSCopying>)identifier {
    [self scheduleBlock:block atTime:time timingContext:context identifier:identifier mainThreadResponseBlock:nil];
}

-(void)scheduleBlock:(AEBlockSchedulerBlock)block atTime:(uint64_t)time timingContext:(AEAudioTimingContext)context identifier:(id<NSCopying>)identifier mainThreadResponseBlock:(AEBlockSchedulerResponseBlock)response {
    NSAssert(identifier != nil && block != nil, @"Identifier and block must not be nil");
    
    uint32_t currentHead = atomic_load_explicit(&_head, memory_order_acquire);
    uint32_t currentTail = atomic_load_explicit(&_tail, memory_order_acquire);
    
    if ( (currentHead+1)%kMaximumSchedules == currentTail ) {
        NSLog(@"Unable to schedule block %@: No space in scheduling table.", identifier);
        return;
    }
    
    struct _schedule_t *schedule = &_schedule[currentHead];
    
    void *currentId    = atomic_load_explicit(&schedule->identifier, memory_order_acquire);
    void *currentBlock = atomic_load_explicit(&schedule->block, memory_order_acquire);
    void *currentResp  = atomic_load_explicit(&schedule->responseBlock, memory_order_acquire);
    atomic_compare_exchange_strong_explicit(&schedule->identifier,
                                            &currentId,
                                            (__bridge_retained void*)[(NSObject*)identifier copy],
                                            memory_order_release,
                                            memory_order_seq_cst);
    atomic_compare_exchange_strong_explicit(&schedule->block,
                                            &currentBlock,
                                            (__bridge_retained void*)[block copy],
                                            memory_order_release,
                                            memory_order_seq_cst);
    atomic_compare_exchange_strong_explicit(&schedule->responseBlock,
                                            &currentResp,
                                            response ? (__bridge_retained void*)[response copy] : NULL,
                                            memory_order_release,
                                            memory_order_seq_cst);
    atomic_store_explicit(&schedule->time, time, memory_order_release);
    atomic_store_explicit(&schedule->context, context, memory_order_release);
    atomic_store_explicit(&_head, (currentHead+1) % kMaximumSchedules, memory_order_release);
    [_scheduledIdentifiers addObject:identifier];
}

-(NSArray *)schedules {
	return [NSArray arrayWithArray:_scheduledIdentifiers];
}

-(void)cancelScheduleWithIdentifier:(id<NSCopying>)identifier {
    NSAssert(identifier != nil, @"Identifier must not be nil");
    
    struct _schedule_t *pointers[kMaximumSchedules];
    struct _schedule_t values[kMaximumSchedules];
    int scheduleCount = 0;
    
    for ( int i=_tail; i != _head; i=(i+1)%kMaximumSchedules ) {
        if ( _schedule[i].identifier && [((__bridge id)_schedule[i].identifier) isEqual:identifier] ) {
            pointers[scheduleCount] = &_schedule[i];
            values[scheduleCount] = _schedule[i];
            scheduleCount++;
        }
    }
    
    if ( scheduleCount == 0 ) return;
    
    struct _schedule_t **pointers_array = pointers;
    [_audioController performSynchronousMessageExchangeWithBlock:^{
        for ( int i=0; i<scheduleCount; i++ ) {
            memset(pointers_array[i], 0, sizeof(struct _schedule_t));
            if ( (pointers_array[i] - self->_schedule) == self->_tail ) {
                while ( !self->_schedule[self->_tail].block && self->_tail != self->_head ) {
                    self->_tail = (self->_tail + 1) % kMaximumSchedules;
                }
            }
        }
    }];

	if ( [_scheduledIdentifiers containsObject:identifier] ) {
		[_scheduledIdentifiers removeObject:identifier];
		for ( int i=0; i<scheduleCount; i++ ) {
			CFBridgingRelease(values[i].block);
			if ( values[i].responseBlock ) {
				CFBridgingRelease(values[i].responseBlock);
			}
			CFBridgingRelease(values[i].identifier);
		}
	}
}

- (NSDictionary*)infoForScheduleWithIdentifier:(id<NSCopying>)identifier {
    struct _schedule_t *schedule = [self scheduleWithIdentifier:identifier];
    if ( !schedule ) return nil;
    
    return @{AEBlockSchedulerKeyBlock: (__bridge id)schedule->block,
            AEBlockSchedulerKeyIdentifier: (__bridge id)schedule->identifier,
            AEBlockSchedulerKeyResponseBlock: schedule->responseBlock ? (__bridge id)schedule->responseBlock : [NSNull null],
            AEBlockSchedulerKeyTimestampInHostTicks: @((long long)schedule->time),
            AEBlockSchedulerKeyTimingContext: @((int)schedule->context)};
}

- (struct _schedule_t*)scheduleWithIdentifier:(id<NSCopying>)identifier {
    for ( int i=_tail; i != _head; i=(i+1)%kMaximumSchedules ) {
        if ( (identifier && _schedule[i].identifier && [((__bridge id)_schedule[i].identifier) isEqual:identifier]) ) {
            return &_schedule[i];
        }
    }
    return NULL;
}

struct _timingReceiverFinishSchedule_t { struct _schedule_t schedule; void *THIS; };
static void timingReceiverFinishSchedule(void *userInfo, int len) {
    struct _timingReceiverFinishSchedule_t *arg = (struct _timingReceiverFinishSchedule_t*)userInfo;
    __unsafe_unretained AEBlockScheduler *THIS = (__bridge AEBlockScheduler*)arg->THIS;
    
    if ( arg->schedule.responseBlock ) {
        ((__bridge_transfer void(^)(void))arg->schedule.responseBlock)();
    }
    CFBridgingRelease(arg->schedule.block);
    
    [THIS->_scheduledIdentifiers removeObject:(__bridge id)arg->schedule.identifier];
    
    CFBridgingRelease(arg->schedule.identifier);
}

static void timingReceiver(__unsafe_unretained AEBlockScheduler *THIS,
                           __unsafe_unretained AEAudioController *audioController,
                           const AudioTimeStamp     *time,
                           UInt32 const              frames,
                           AEAudioTimingContext      context) {
    uint64_t endTime = time->mHostTime + AEConvertFramesToSeconds(audioController, frames)*__secondsToHostTicks;
    
    for ( int i=THIS->_tail; i != THIS->_head; i=(i+1)%kMaximumSchedules ) {
        if ( THIS->_schedule[i].block && THIS->_schedule[i].context == context && THIS->_schedule[i].time && endTime >= THIS->_schedule[i].time ) {
            UInt32 offset = THIS->_schedule[i].time > time->mHostTime ? (UInt32)AEConvertSecondsToFrames(audioController, (THIS->_schedule[i].time - time->mHostTime)*__hostTicksToSeconds) : 0;
            ((__bridge AEBlockSchedulerBlock)THIS->_schedule[i].block)(time, offset);
            AEAudioControllerSendAsynchronousMessageToMainThread(audioController,
                                                                 timingReceiverFinishSchedule,
                                                                 &(struct _timingReceiverFinishSchedule_t) { .schedule = THIS->_schedule[i], .THIS = (__bridge void *)THIS },
                                                                 sizeof(struct _timingReceiverFinishSchedule_t));
            memset(&THIS->_schedule[i], 0, sizeof(struct _schedule_t));
            if ( i == THIS->_tail ) {
                while ( !THIS->_schedule[THIS->_tail].block && THIS->_tail != THIS->_head ) {
                    atomic_store_explicit(&THIS->_tail, (THIS->_tail + 1) % kMaximumSchedules, memory_order_release);
                }
            }
        }
    }
}

-(AEAudioTimingCallback)timingReceiverCallback {
    return timingReceiver;
}

@end
