/*******************************************************************************
 * Copyright (C) 2005-2017 Alfresco Software Limited.
 *
 * This file is part of the Alfresco Mobile iOS App.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 ******************************************************************************/

#import <Foundation/Foundation.h>
#import "ConfigurationFilesUtils.h"
#import "AlfrescoConfigService.h"

@interface AccountConfiguration : NSObject

@property (nonatomic, strong) AlfrescoConfigService *configService;
@property (nonatomic, strong) UserAccount *account;
@property (nonatomic, strong) id<AlfrescoSession> session;
@property (nonatomic, strong) AlfrescoProfileConfig *selectedProfile;

- (instancetype)initWithAccount:(UserAccount *)account session:(id<AlfrescoSession>)session;
- (instancetype)initWithNoAccounts;

- (void)install;
- (void)switchToConfigurationFileType:(ConfigurationFileType)configurationFileType;
- (void)retrieveProfilesWithCompletionBlock:(AlfrescoArrayCompletionBlock)completionBlock;
- (void)retrieveDefaultProfileWithCompletionBlock:(AlfrescoProfileConfigCompletionBlock)completionBlock;
- (BOOL)isEmbeddedConfigurationLoaded;

@end
