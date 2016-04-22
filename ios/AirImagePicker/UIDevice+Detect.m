//////////////////////////////////////////////////////////////////////////////////////
//
//  Copyright 2011-2016 VoiceThread (https://voicethread.com/)
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//////////////////////////////////////////////////////////////////////////////////////

#import "UIDevice+Detect.h"

@implementation UIDevice (Detect)

+ (BOOL)hasLargeScreen {
  return(
    [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad);
}

+ (BOOL)hasFlatInterface {
  static BOOL cached;
  static BOOL value;
  if (! cached) {
    cached = YES;
    if ([UIDevice.currentDevice.systemVersion
      compare:@"7.0" options:NSNumericSearch] != NSOrderedAscending)
        value = YES;
    else
      value = NO;
  }
  return(value);
}

@end