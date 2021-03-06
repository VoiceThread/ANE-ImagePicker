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

#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVFoundation.h>

#import "AirImagePicker.h"
#import "AssetPickerController.h"
#import "AlbumListController.h"

#import "NSURL+Rewriters.h"

// private methods
@interface AssetPickerController()

// process a list of assets
- (void)processAssets:(NSArray *)assets;
// process a specific asset and return whether processing was completed
//  synchronously (returning NO indicates that some asynchronous processing
//  was required and that the processing of other assets should be delayed
//  until it completes)
- (void)processALAsset:(ALAsset *)asset;
- (void)processPHAsset:(PHAsset *)asset;
// indicate that all asset processing is finished
- (void)assetProcessingDidFinish;

- (NSFileHandle *)fileHandleForUrl:(NSURL *)url;
- (void)saveData:(NSData *)data forAsset:(PHAsset *)asset toURL:(NSURL *)url;

@end

@implementation AssetPickerController

- (float)progress {
  if (progressDict) {
    double sum = 0.0, total = 0.0;
    for (NSObject *p in [progressDict allValues]) {
      if ([p isKindOfClass:[NSNumber class]]) {
        sum += [p doubleValue];
      }
      else if ([p isKindOfClass:[AVAssetExportSession class]]) {
        sum += 0.5 + ((float)[(AVAssetExportSession *)p progress] / 2.0);
      }
      total += 1.0;
    }
    _progress = sum / total;
  }
  return(_progress);
}

- (id)init {
  // show the user's photo albums
  AlbumListController *albums = [[[AlbumListController alloc] 
    initWithStyle:UITableViewStylePlain]
      autorelease];
  // put them in a navigation controller
  if ((self = [super initWithRootViewController:albums])) {
    _progress = 0.0;
  }
  return(self);
}
- (void)dealloc {
  [progressVC release], progressVC = nil;
  [progressDict release], progressDict = nil;
  [super dealloc];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  // always use the iPhone screen size 
  //  (on iPad it will be inside a popover)
  [self setContentSizeForViewInPopover:CGSizeMake(320.0, 480.0)];
}

// respond to the picking being cancelled
- (void)cancel {
  [self assetProcessingDidFinish];
}

// respond to a list of assets being selected
- (void)didSelectAssets:(NSArray *)assets {
  // show a view to let the user know assets are being processed
  if (progressVC == nil) {
    progressVC = [[ProgressController alloc]
      initWithTaskNamed:@"Processing Media"
      progressTarget:self];
  }
  [self presentViewController:progressVC animated:NO completion:nil];
  [self processAssets:assets];
}
- (void)processAssets:(NSArray *)assets {
  // handle Photos assets
  if ([[assets firstObject] isKindOfClass:[PHAsset class]]) {
    progressDict = [[NSMutableDictionary alloc] init];
    assetsTotal = [assets count];
    assetsCompleted = 0;
    for (PHAsset *asset in assets) {
      [progressDict setObject:[NSNumber numberWithDouble:0.0] forKey:asset];
      [self processPHAsset:asset];
    }
  }
  // handle Asset Library assets
  else if ([[assets firstObject] isKindOfClass:[ALAsset class]]) {
    // get the total size of all assets
    totalBytes = 0;
    for (ALAsset *asset in assets) {
      totalBytes += [[asset defaultRepresentation] size];
    }
    processedBytes = 0;
    // process assets on another thread
    dispatch_queue_t thread = dispatch_queue_create("asset copy", NULL);
    dispatch_async(thread, ^{
      for (ALAsset *asset in assets) {
        [self processALAsset:asset];
      }
      [self assetProcessingDidFinish];
    });
    dispatch_release(thread);
  }
  else {
    [self assetProcessingDidFinish];
  }
}

// get a file handle for a file
- (NSFileHandle *)fileHandleForUrl:(NSURL *)url {
  NSError *error = nil;
  // create the temp file (or we can't open for writing below)
  if (! [[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
    BOOL created = [[NSFileManager defaultManager] 
                      createFileAtPath:[url path] 
                      contents:nil attributes:nil];
    if (! created) {
      NSLog(@"AirImagePicker:  Error creating temp file");
      return(nil);
    }
  }
  // open the file for writing
  NSFileHandle *fileHandle = 
    [NSFileHandle fileHandleForWritingToURL:url error:&error];
  if (fileHandle == nil) {
    NSLog(@"AirImagePicker:  Error opening temp file for writing: %@", 
            [error description]);
    return(nil);
  }
  return(fileHandle);
}

// process a single asset from the pending list
- (void)processALAsset:(ALAsset *)asset {
  // get a temp file location to move the data to
  NSURL *toURL = [NSURL tempFileURLWithPrefix:@"temp-AirImagePicker" extension:@"tmp"];
  // get the main representation of the media
  ALAssetRepresentation *rep = [(ALAsset *)asset defaultRepresentation];
  // copy the asset data to the temp file in chunks
  long long offset = 0;
  NSUInteger bytesRead = 0;
  uint8_t buffer[16 * 1024]; // 16K data buffer
  NSError *error = nil;
  NSFileHandle *fileHandle = [self fileHandleForUrl:toURL];
  if (fileHandle == nil) return;
  int fd = [fileHandle fileDescriptor];
  do {
    // read a chunk
    bytesRead = [rep getBytes:buffer fromOffset:offset length:sizeof(buffer) 
                 error:&error];
    if (error != nil) {
      NSLog(@"AirImagePicker:  Error writing to temp file: %@", 
          [error description]);
      return;
    }
    offset += bytesRead;
    processedBytes += bytesRead;
    // write a chunk
    write(fd, buffer, bytesRead);
    // update progress
    _progress = (float)processedBytes / (float)totalBytes;
  }
  while (offset < [rep size]);
  // make sure the file is completely written to disk
  [fileHandle synchronizeFile];
  [fileHandle closeFile];
  // return the URL to the client
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([self.delegate respondsToSelector:@selector(assetPickerController:didPickMediaWithURL:)]) {
      [(NSObject<AssetPickerControllerDelegate> *)self.delegate 
        assetPickerController:self didPickMediaWithURL:toURL];
    }
  });
}
- (void)processPHAsset:(PHAsset *)asset {
  // use the resources framework to source data if we have iOS 9+
  if ((USE_IOS_9) && ([[UIDevice currentDevice].systemVersion intValue] >= 9)) {
    NSArray *resources = [PHAssetResource assetResourcesForAsset:(PHAsset *)asset];
    // get the type of resource we want to use
    PHAssetResourceType expectedType = PHAssetResourceTypePhoto;
    if (asset.mediaType == PHAssetMediaTypeVideo) 
      expectedType = PHAssetResourceTypeVideo;
    if (asset.mediaType == PHAssetMediaTypeAudio) 
      expectedType = PHAssetResourceTypeAudio;
    // iterate resources for the asset
    for (PHAssetResource *resource in resources) {
      // handle only the main resource types
      if (resource.type != expectedType) continue;
      // allow network fetches and monitor progress
      PHAssetResourceRequestOptions *resOptions = 
        [[[PHAssetResourceRequestOptions alloc] init] autorelease];
      resOptions.networkAccessAllowed = YES;
      resOptions.progressHandler = ^(double p) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [progressDict setObject:[NSNumber numberWithDouble:p] forKey:asset];
          });
        };
      // copy the resource data to a file
      dispatch_queue_t resThread = dispatch_queue_create("asset copy", NULL);
      dispatch_async(resThread, ^{
        NSURL *toURL = [NSURL tempFileURLWithPrefix:@"temp-AirImagePicker" extension:@"tmp"];
        [[PHAssetResourceManager defaultManager] 
          writeDataForAssetResource:resource toFile:toURL
          options:resOptions 
          completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
              if (error) NSLog(@"AirImagePicker:  Resource request failed: %@", error); 
              else if ([self.delegate respondsToSelector:@selector(assetPickerController:didPickMediaWithURL:)]) {
                [(NSObject<AssetPickerControllerDelegate> *)self.delegate 
                  assetPickerController:self didPickMediaWithURL:toURL];
              }
              assetsCompleted++;
              if (assetsCompleted >= assetsTotal) {
                [self assetProcessingDidFinish];
              }
            });
          }];
      });
      dispatch_release(resThread);
      return;
    }
    // if we get here, there are no supported resource types
    NSLog(@"AirImagePicker:  The expected resource type %li was not found for media type %li.", 
      (long)expectedType, (long)asset.mediaType);
    assetsCompleted++;
    if (assetsCompleted >= assetsTotal) {
      [self assetProcessingDidFinish];
    }
  }
  // use the imagemanager with an export session to request video data in iOS 8
  else if ((asset.mediaType == PHAssetMediaTypeVideo) ||
           (asset.mediaType == PHAssetMediaTypeAudio)) {
    // fetch videos from the network
    PHVideoRequestOptions *vidOptions = 
      [[[PHVideoRequestOptions alloc] init] autorelease];
    vidOptions.networkAccessAllowed = YES;
    vidOptions.deliveryMode = PHVideoRequestOptionsDeliveryModeMediumQualityFormat;
    // show video fetch progress
    vidOptions.progressHandler = ^(double progress, NSError *error, BOOL *stop, NSDictionary *info) {
        if (error) NSLog(@"AirImagePicker:  Video data request failed: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressDict setObject:[NSNumber numberWithDouble:(progress / 2.0)] forKey:asset];
        });
      };
    // fetch the video
    [[PHImageManager defaultManager] requestExportSessionForVideo:asset 
      options:vidOptions exportPreset:AVAssetExportPresetPassthrough 
      resultHandler:^(AVAssetExportSession *exportSession, NSDictionary *info) {
        // detect failure to download videos from iCloud, which is not allowed 
        //  on iOS: https://discussions.apple.com/thread/5364797?tstart=0
        if ([[NSNumber numberWithBool:YES] isEqualToNumber:
              [info objectForKey:PHImageResultIsInCloudKey]]) {
          // show an alert
          UIAlertController* alert = 
            [UIAlertController alertControllerWithTitle:@"Download Failed"
              message:@"You can only import video from your camera roll. "
                      @"If you move this video into your camera roll first, "
                      @"you can upload it from there."
              preferredStyle:UIAlertControllerStyleAlert];
          // when the user taps OK, exit the interface if we're done processing
          assetsCompleted++;
          UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"OK" 
            style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
              if (assetsCompleted >= assetsTotal) {
                [self assetProcessingDidFinish];
              }
            }];
          [alert addAction:defaultAction];
          dispatch_async(dispatch_get_main_queue(), ^{
            [progressVC presentViewController:alert animated:YES completion:nil];
          });
          return;
        }
        // make a temp file
        NSURL *toURL = [NSURL tempFileURLWithPrefix:@"temp-AirImagePicker" extension:@"tmp"];
        exportSession.outputURL = toURL;
        // export to quicktime or mp3
        if (asset.mediaType == PHAssetMediaTypeAudio) 
          exportSession.outputFileType = AVFileTypeMPEGLayer3;
        else
          exportSession.outputFileType = AVFileTypeQuickTimeMovie;
        // export video to the temp file
        [exportSession exportAsynchronouslyWithCompletionHandler:^{
          if (exportSession.status == AVAssetExportSessionStatusCompleted) {
            // tell the delegate we got the media
            dispatch_async(dispatch_get_main_queue(), ^{
              if ([self.delegate respondsToSelector:@selector(assetPickerController:didPickMediaWithURL:)]) {
                [(NSObject<AssetPickerControllerDelegate> *)self.delegate 
                  assetPickerController:self didPickMediaWithURL:toURL];
              }
            });
          }
          else {
            NSLog(@"AirImagePicker:  Export session failed with status %li", exportSession.status);
          }
          assetsCompleted++;
          if (assetsCompleted >= assetsTotal) {
            [self assetProcessingDidFinish];
          }
        }];
        // track the progress of the export session
        [progressDict setObject:exportSession forKey:asset];
      }];
  }
  // use the imagemanager to source image data in iOS 8
  else {
    // fetch images from the network
    PHImageRequestOptions *imgOptions = 
      [[[PHImageRequestOptions alloc] init] autorelease];
    imgOptions.networkAccessAllowed = YES;
    imgOptions.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
    // show image fetch progress
    imgOptions.progressHandler = ^(double progress, NSError *error, BOOL *stop, NSDictionary *info) {
        if (error) NSLog(@"AirImagePicker:  Image data request failed: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressDict setObject:[NSNumber numberWithDouble:(progress / 2.0)] forKey:asset];
        });
      };
    // fetch the image data
    [[PHImageManager defaultManager] requestImageDataForAsset:asset 
      options:imgOptions 
      resultHandler:^(NSData *imageData, NSString *dataUTI,
                      UIImageOrientation orientation, NSDictionary *info) {  
        if (! imageData) {
          assetsCompleted++;
          return;
        }
        dispatch_queue_t imgThread = dispatch_queue_create("asset copy", NULL);
        dispatch_async(imgThread, ^{
          NSURL *toURL = [NSURL tempFileURLWithPrefix:@"temp-AirImagePicker" extension:@"tmp"];
          [self saveData:imageData forAsset:asset toURL:toURL];
          // see if we've processed all media
          assetsCompleted++;
          if (assetsCompleted >= assetsTotal) {
            [self assetProcessingDidFinish];
          }
        });
        dispatch_release(imgThread);
      }];
  }
}
- (void)saveData:(NSData *)data forAsset:(PHAsset *)asset toURL:(NSURL *)toURL {
  long long offset = 0;
  NSUInteger size = [data length];
  uint8_t buffer[16 * 1024]; // 16K data buffer
  NSFileHandle *fileHandle = [self fileHandleForUrl:toURL];
  if (fileHandle == nil) return;
    int fd = [fileHandle fileDescriptor];
    do {
      NSUInteger chunkSize = sizeof(buffer);
      if (offset + chunkSize >= size) chunkSize = size - offset;
      NSRange chunk = NSMakeRange(offset, chunkSize);
      // read a chunk
      [data getBytes:buffer range:chunk];
      offset += chunkSize;
      // write a chunk
      write(fd, buffer, chunkSize);
      // update progress
      dispatch_async(dispatch_get_main_queue(), ^{
        [progressDict setObject:
          [NSNumber numberWithDouble:(0.5 + (0.5 * ((double)offset / (double)size)))] 
          forKey:asset];
      });
    }
    while (offset < size);
    // make sure the file is completely written to disk
    [fileHandle synchronizeFile];
    [fileHandle closeFile];
    // notify the delegate
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([self.delegate respondsToSelector:@selector(assetPickerController:didPickMediaWithURL:)]) {
        [(NSObject<AssetPickerControllerDelegate> *)self.delegate 
          assetPickerController:self didPickMediaWithURL:toURL];
      }
    });
}

- (void)assetProcessingDidFinish {
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([self.delegate respondsToSelector:@selector(assetPickerControllerDidFinish:)]) {
      [(NSObject<AssetPickerControllerDelegate> *)self.delegate 
        assetPickerControllerDidFinish:self];
    }
  });
}

@end
