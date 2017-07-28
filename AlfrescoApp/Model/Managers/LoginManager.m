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
 
#import "AppDelegate.h"
#import "UniversalDevice.h"
#import "LoginManager.h"
#import "LoginViewController.h"
#import "NavigationViewController.h"
#import "ConnectivityManager.h"
#import "UserAccount.h"
#import "AccountManager.h"
#import "NavigationViewController.h"

@interface LoginManager()
@property (nonatomic, strong) MBProgressHUD *progressHUD;
@property (nonatomic, strong) __block NSString *currentLoginURLString;
@property (nonatomic, strong) __block AlfrescoRequest *currentLoginRequest;
@property (nonatomic, strong) AlfrescoOAuthUILoginViewController *loginController;
@property (nonatomic, strong) AlfrescoSAMLUILoginViewController *samlLoginController;
@property (nonatomic, copy) void (^authenticationCompletionBlock)(BOOL success, id<AlfrescoSession> alfrescoSession, NSError *error);
@property (nonatomic, assign) BOOL didCancelLogin;
@property (nonatomic, assign) BOOL completionBlockCalledFromLoginViewController;
@property (nonatomic, assign, readwrite) BOOL sessionExpired;
// Cloud parameters
@property (nonatomic, strong) NSString *cloudAPIKey;
@property (nonatomic, strong) NSString *cloudSecretKey;

@property (nonatomic, assign) BOOL loginAttemptInProgress;
@property (nonatomic, copy) void (^signInAlertCompletionBlock)();
@end

@implementation LoginManager

#pragma mark - Public Functions

+ (LoginManager *)sharedManager
{
    static dispatch_once_t onceToken;
    static LoginManager *sharedLoginManager = nil;
    dispatch_once(&onceToken, ^{
        sharedLoginManager = [[self alloc] init];
    });
    return sharedLoginManager;
}

- (id)init
{
    self = [super init];
    if (self)
    {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(unauthorizedAccessNotificationReceived:) name:kAlfrescoAccessDeniedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:kAlfrescoConnectivityChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tokenExpired:) name:kAlfrescoTokenExpiredNotification object:nil];
    }
    return self;
}

- (void)attemptLoginToAccount:(UserAccount *)account networkId:(NSString *)networkId completionBlock:(LoginAuthenticationCompletionBlock)loginCompletionBlock
{
    if (self.loginAttemptInProgress)
    {
        return;
    }
    
    self.loginAttemptInProgress = YES;
    
    
    __weak typeof(self)weakSelf = self;
    self.authenticationCompletionBlock = ^(BOOL successful, id<AlfrescoSession> session, NSError *error){
        if (successful)
        {
            weakSelf.sessionExpired = NO;
        }
        
        if (loginCompletionBlock != NULL)
        {
            loginCompletionBlock(successful, session, error);
        }
    };
    
    if ([[ConnectivityManager sharedManager] hasInternetConnection])
    {
        AppDelegate *delegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
        [self showHUDOnView:delegate.window];
        
        if (account.accountType == UserAccountTypeOnPremise)
        {
            NSString *urlString = [Utility serverURLStringFromAccount:account];
            
            [AlfrescoSAMLAuthHelper checkIfSAMLIsEnabledForServerWithUrlString:urlString completionBlock:^(AlfrescoSAMLData *samlData, NSError *error) {
                [self hideHUD];
                
                void (^showSAMLWebViewAndAuthenticate)() = ^void (){
                    [self showSAMLWebViewForAccount:account navigationController:nil completionBlock:^(AlfrescoSAMLData *samlData, NSError *error)
                     {
                         if (samlData)
                         {
                             account.samlData.samlTicket = samlData.samlTicket;
                             [self authenticateWithSAMLOnPremiseAccount:account navigationController:nil completionBlock:^(BOOL successful, id<AlfrescoSession> alfrescoSession, NSError *error) {
                                 if (successful)
                                 {
                                     [[NSNotificationCenter defaultCenter] postNotificationName:kAlfrescoSessionRefreshedNotification object:alfrescoSession];
                                 }
                                 self.authenticationCompletionBlock(successful, alfrescoSession, error);
                                 self.loginAttemptInProgress = NO;
                                 [self.samlLoginController dismissViewControllerAnimated:YES completion:nil];
                             }];
                         }
                     }];
                };
                
                if (error || [samlData isSamlEnabled] == NO) // SAML not enabled
                {
                    BOOL switchedAuthenticationMethod = NO;
                    
                    if (account.samlData)
                    {
                        switchedAuthenticationMethod = YES;
                    }
                    account.samlData = nil;
                    
                    if (switchedAuthenticationMethod)
                    {
                        self.sessionExpired = YES;
                        
                        self.signInAlertCompletionBlock = ^{
                            if (account.username.length == 0 || account.password.length == 0)
                            {
                                [weakSelf hideHUD];
                                [weakSelf displayLoginViewControllerWithAccount:account username:account.username];
                                weakSelf.authenticationCompletionBlock(NO, nil, nil);
                                weakSelf.loginAttemptInProgress = NO;
                                return;
                            }
                            
                            [weakSelf authenticateOnPremiseAccount:account password:account.password completionBlock:^(BOOL successful, id<AlfrescoSession> session, NSError *error) {
                                [weakSelf hideHUD];
                                if(successful)
                                {
                                    weakSelf.sessionExpired = NO;
                                    [[NSNotificationCenter defaultCenter] postNotificationName:kAlfrescoSessionRefreshedNotification object:session];
                                }
                                if (error && error.code != kAlfrescoErrorCodeNoNetworkConnection && error.code != kAlfrescoErrorCodeNetworkRequestCancelled)
                                {
                                    [weakSelf displayLoginViewControllerWithAccount:account username:account.username];
                                }
                                weakSelf.authenticationCompletionBlock(successful, session, error);
                                weakSelf.loginAttemptInProgress = NO;
                            }];
                        };
                        
                        [self showSignInAlertWithSignedInBlock:self.signInAlertCompletionBlock];
                    }
                    else
                    {
                        if (account.username.length == 0 || account.password.length == 0)
                        {
                            [self hideHUD];
                            [self displayLoginViewControllerWithAccount:account username:account.username];
                            self.authenticationCompletionBlock(NO, nil, nil);
                            self.loginAttemptInProgress = NO;
                            return;
                        }
                        
                        [self authenticateOnPremiseAccount:account password:account.password completionBlock:^(BOOL successful, id<AlfrescoSession> session, NSError *error) {
                            [self hideHUD];
                            if(successful)
                            {
                                [[NSNotificationCenter defaultCenter] postNotificationName:kAlfrescoSessionRefreshedNotification object:session];
                            }
                            if (error && error.code != kAlfrescoErrorCodeNoNetworkConnection && error.code != kAlfrescoErrorCodeNetworkRequestCancelled)
                            {
                                [self displayLoginViewControllerWithAccount:account username:account.username];
                            }
                            self.authenticationCompletionBlock(successful, session, error);
                            self.loginAttemptInProgress = NO;
                        }];
                    }
                }
                else // SAML enabled
                {
                    if (account.samlData)
                    {
                        // The IDP might have been changed. Set the SAMLInfo.
                        account.samlData.samlInfo = samlData.samlInfo;
                        
                        if (account.samlData.samlTicket)
                        {
                            [self authenticateWithSAMLOnPremiseAccount:account navigationController:nil completionBlock:^(BOOL successful, id<AlfrescoSession> alfrescoSession, NSError *error) {
                                [self hideHUD];
                                
                                if (error)
                                {
                                    account.samlData.samlTicket = nil;
                                    showSAMLWebViewAndAuthenticate();
                                }
                                else
                                {
                                    self.authenticationCompletionBlock(successful, alfrescoSession, nil);
                                    self.loginAttemptInProgress = NO;
                                }
                            }];
                        }
                        else
                        {
                            showSAMLWebViewAndAuthenticate();
                        }
                    }
                    else
                    {
                        account.samlData = samlData;
                        
                        self.sessionExpired = YES;
                        
                        self.signInAlertCompletionBlock = ^{
                            showSAMLWebViewAndAuthenticate();
                        };
                        [self showSignInAlertWithSignedInBlock:self.signInAlertCompletionBlock];
                    }
                }
            }];
        }
        else
        {
            [self authenticateCloudAccount:account networkId:networkId navigationController:nil completionBlock:^(BOOL successful, id<AlfrescoSession> session, NSError *error) {
                [self hideHUD];
                if(successful)
                {
                    [[NSNotificationCenter defaultCenter] postNotificationName:kAlfrescoSessionRefreshedNotification object:session];
                }
                if (loginCompletionBlock)
                {
                    loginCompletionBlock(successful, session, error);
                }
                self.loginAttemptInProgress = NO;
            }];
        }
    }
    else if (![[AccountManager sharedManager].selectedAccount.accountIdentifier isEqualToString:account.accountIdentifier])
    {
        // Assuming there is no internet connection and the user tries to switch account.
        self.authenticationCompletionBlock(YES, nil, nil);
        self.loginAttemptInProgress = NO;
    }
    else
    {
        NSError *unreachableError = [NSError errorWithDomain:kAlfrescoErrorDomainName code:kAlfrescoErrorCodeNoNetworkConnection userInfo:nil];
        self.authenticationCompletionBlock(NO, nil, unreachableError);
        self.loginAttemptInProgress = NO;
    }
}

- (void)showSignInAlertWithSignedInBlock:(void (^)())completionBlock
{
    if (completionBlock == nil)
    {
        completionBlock = self.signInAlertCompletionBlock;
    }
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"error.host.unreachable.title", @"Connection Error")
                                                                             message:NSLocalizedString(@"error.session.expired", @"Your session has expired. Sign in to continue.")
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *signInAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"login.sign.in", @"Sign In") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (completionBlock)
        {
            completionBlock();
        }
    }];
    
    [alertController addAction:signInAction];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"OK") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [alertController dismissViewControllerAnimated:YES completion:nil];
    }];
    
    [alertController addAction:okAction];
    
    AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    [UniversalDevice displayModalViewController:alertController onController:appDelegate.window.rootViewController withCompletionBlock:nil];
}

#pragma mark - SAML Authentication Methods

- (void)showSAMLWebViewForAccount:(UserAccount *)account navigationController:(UINavigationController *)navigationController completionBlock:(AlfrescoSAMLAuthCompletionBlock)completionBlock
{
    NSString *urlString = [Utility serverURLStringFromAccount:account];
    
    AlfrescoSAMLUILoginViewController *lvc = [[AlfrescoSAMLUILoginViewController alloc] initWithBaseURLString:urlString completionBlock:^(AlfrescoSAMLData *alfrescoSamlData, NSError *error) {
        
        if (completionBlock)
        {
            completionBlock(alfrescoSamlData, error);
        }
    }];
    
    if (navigationController)
    {
        [navigationController pushViewController:lvc animated:YES];
    }
    else
    {
        navigationController = [[NavigationViewController alloc] initWithRootViewController:lvc];
        UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                target:self
                                                                                action:@selector(cancelSamlAuthentication:)];
        lvc.navigationItem.leftBarButtonItem = cancel;
        lvc.modalPresentationStyle = UIModalPresentationFormSheet;
        self.samlLoginController = lvc;
        
        AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
        [UniversalDevice displayModalViewController:navigationController onController:appDelegate.window.rootViewController withCompletionBlock:nil];
    }

}

- (void)authenticateWithSAMLOnPremiseAccount:(UserAccount *)account
                navigationController:(UINavigationController *)navigationController
                     completionBlock:(LoginAuthenticationCompletionBlock)authenticationCompletionBlock
{
    NSString *urlString = [Utility serverURLStringFromAccount:account];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (account.samlData.samlTicket)
    {
        [AlfrescoRepositorySession connectWithUrl:url
                                         SAMLData:account.samlData
                                  completionBlock:^(id<AlfrescoSession> session, NSError *error) {
                                      if (authenticationCompletionBlock)
                                      {
                                          if (session)
                                          {
                                              authenticationCompletionBlock(YES, session, nil);
                                          }
                                          else
                                          {
                                              authenticationCompletionBlock(NO, nil, error);
                                          }
                                      }
                                  }];
    }
    else
    {
        authenticationCompletionBlock(NO, nil, nil);
    }
}

- (void)cancelSamlAuthentication:(id)sender
{
    [self.samlLoginController dismissViewControllerAnimated:YES completion:^{
        self.loginAttemptInProgress = NO;
        
        if (self.authenticationCompletionBlock != NULL)
        {
            self.authenticationCompletionBlock(NO, nil, nil);
        }
    }];
}

#pragma mark - Cloud authentication Methods

- (void)authenticateCloudAccount:(UserAccount *)account
                       networkId:(NSString *)networkId
            navigationController:(UINavigationController *)navigationController
                 completionBlock:(LoginAuthenticationCompletionBlock)authenticationCompletionBlock
{
    self.didCancelLogin = NO;
    self.authenticationCompletionBlock = authenticationCompletionBlock;

    NSDictionary *customParameters = [self loadCustomCloudOAuthParameters];
    
    void (^authenticationComplete)(id<AlfrescoSession>, NSError *error) = ^(id<AlfrescoSession> session, NSError *error) {
        if (error)
        {
            if (authenticationCompletionBlock != NULL)
            {
                authenticationCompletionBlock(NO, session, error);
            }
        }
        else
        {
            if (!self.didCancelLogin)
            {
                self.currentLoginRequest = [(AlfrescoCloudSession *)session retrieveNetworksWithCompletionBlock:^(NSArray *networks, NSError *error) {
                    if (networks && error == nil)
                    {
                        // Primary sort: isHomeNetwork
                        NSSortDescriptor *homeNetworkSortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"isHomeNetwork" ascending:NO];
                        // Seconday sort: alphabetical by identifier
                        NSSortDescriptor *identifierSortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"identifier" ascending:YES];
                        
                        NSArray *sortedNetworks = [networks sortedArrayUsingDescriptors:@[homeNetworkSortDescriptor, identifierSortDescriptor]];
                        account.accountNetworks = [sortedNetworks valueForKeyPath:@"identifier"];
                        
                        // The home network defines the user's account paid status
                        account.paidAccount = ((AlfrescoCloudNetwork *)sortedNetworks[0]).isPaidNetwork;
                        
                        if (authenticationCompletionBlock != NULL)
                        {
                            authenticationCompletionBlock(YES, session, error);
                        }
                    }
                    else
                    {
                        if (authenticationCompletionBlock != NULL)
                        {
                            authenticationCompletionBlock(NO, nil, error);
                        }
                    }
                }];
            }
        }
    };
    
    AlfrescoOAuthUILoginViewController * (^showOAuthLoginViewController)(void) = ^AlfrescoOAuthUILoginViewController * (void) {
        [self hideHUD];
        NavigationViewController *oauthNavigationController = nil;

        AlfrescoOAuthUILoginViewController *oauthLoginController = [[AlfrescoOAuthUILoginViewController alloc] initWithAPIKey:self.cloudAPIKey secretKey:self.cloudSecretKey parameters:customParameters completionBlock:^(AlfrescoOAuthData *oauthData, NSError *error) {
            if (oauthData)
            {
                account.oauthData = oauthData;
                
                self.currentLoginRequest = [self connectWithOAuthData:oauthData networkId:networkId completionBlock:^(id<AlfrescoSession> session, NSError *error) {
                    if (navigationController)
                    {
                        [navigationController popViewControllerAnimated:YES];
                    }
                    else
                    {
                        [self.loginController dismissViewControllerAnimated:YES completion:nil];
                    }
                    
                    authenticationComplete(session, error);
                }];
            }
            else
            {
                authenticationComplete(nil, error);
            }
        }];
        
        if (navigationController)
        {
            [navigationController pushViewController:oauthLoginController animated:YES];
        }
        else
        {
            oauthNavigationController = [[NavigationViewController alloc] initWithRootViewController:oauthLoginController];
            UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                    target:self
                                                                                    action:@selector(cancelCloudAuthentication:)];
            oauthLoginController.navigationItem.leftBarButtonItem = cancel;
            oauthNavigationController.modalPresentationStyle = UIModalPresentationFormSheet;
            
            AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
            [UniversalDevice displayModalViewController:oauthNavigationController onController:appDelegate.window.rootViewController withCompletionBlock:nil];
        }
        return oauthLoginController;
    };
    
    if (account.oauthData)
    {
        self.currentLoginRequest = [self connectWithOAuthData:account.oauthData networkId:networkId completionBlock:^(id<AlfrescoSession> cloudSession, NSError *connectionError) {
            [navigationController popViewControllerAnimated:YES];
            if (nil == cloudSession)
            {
                if (connectionError.code == kAlfrescoErrorCodeAccessTokenExpired)
                {
                    // refresh token
                    AlfrescoOAuthHelper *oauthHelper = [[AlfrescoOAuthHelper alloc] initWithParameters:customParameters delegate:self];
                    self.currentLoginRequest = [oauthHelper refreshAccessToken:account.oauthData completionBlock:^(AlfrescoOAuthData *refreshedOAuthData, NSError *refreshError) {
                        if (nil == refreshedOAuthData)
                        {
                            // if refresh token is expired or invalid present OAuth LoginView
                            if (refreshError.code == kAlfrescoErrorCodeRefreshTokenExpired || refreshError.code == kAlfrescoErrorCodeRefreshTokenInvalid)
                            {
                                self.loginController = showOAuthLoginViewController();
                                self.loginController.oauthDelegate = self;
                            }
                            authenticationComplete(nil, refreshError);
                        }
                        else
                        {
                            account.oauthData = refreshedOAuthData;
                            [[AccountManager sharedManager] saveAccountsToKeychain];
                            
                            // try to connect once OAuthData is refreshed
                            if (!self.didCancelLogin)
                            {
                                self.currentLoginRequest = [self connectWithOAuthData:refreshedOAuthData networkId:networkId completionBlock:^(id<AlfrescoSession> retrySession, NSError *retryError) {
                                    authenticationComplete(retrySession, retryError);
                                }];
                            }
                        }
                    }];
                }
                else
                {
                    authenticationComplete(nil, connectionError);
                }
            }
            else
            {
                authenticationComplete(cloudSession, connectionError);
            }
        }];
    }
    else
    {
        self.loginController = showOAuthLoginViewController();
        self.loginController.oauthDelegate = self;
    }
}

- (AlfrescoRequest *)connectWithOAuthData:(AlfrescoOAuthData *)oauthData networkId:(NSString *)networkId completionBlock:(AlfrescoSessionCompletionBlock)completionBlock
{
    AlfrescoRequest *cloudRequest = nil;
    NSDictionary *customParameters = [self loadCustomCloudOAuthParameters];
    
    if (networkId)
    {
        cloudRequest = [AlfrescoCloudSession connectWithOAuthData:oauthData networkIdentifer:networkId parameters:customParameters completionBlock:completionBlock];
    }
    else
    {
        cloudRequest = [AlfrescoCloudSession connectWithOAuthData:oauthData parameters:customParameters completionBlock:completionBlock];
    }
    
    return cloudRequest;
}

- (void)cancelCloudAuthentication:(id)sender
{
    [self.loginController dismissViewControllerAnimated:YES completion:^{
        if (self.authenticationCompletionBlock != NULL)
        {
            self.authenticationCompletionBlock(NO, nil, nil);
        }
    }];
}

- (NSDictionary *)loadCustomCloudOAuthParameters
{
    NSDictionary *parameters = nil;
    
    // Initially reset to defaults
    self.cloudAPIKey = CLOUD_OAUTH_KEY;
    self.cloudSecretKey = CLOUD_OAUTH_SECRET;
    
    // Checks for a cloud-config.plist file in the "Local Files" area with custom connection parameters
    NSString *plistPath = [[[AlfrescoFileManager sharedManager] downloadsContentFolderPath] stringByAppendingPathComponent:kCloudConfigFile];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *customCloudURL = config[kCloudConfigParamURL];

    if (config && customCloudURL)
    {
        self.cloudAPIKey = config[kCloudConfigParamAPIKey];
        self.cloudSecretKey = config[kCloudConfigParamSecretKey];
        parameters = @{kInternalSessionCloudURL: customCloudURL};
    }
    
    return parameters;
}

#pragma mark - OAuth delegate

- (void)oauthLoginDidFailWithError:(NSError *)error
{
    AlfrescoLogDebug(@"OAuth Failed");
}

#pragma mark - Private Functions

- (void)displayLoginViewControllerWithAccount:(UserAccount *)account username:(NSString *)username
{
    AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    
    LoginViewController *loginViewController = [[LoginViewController alloc] initWithAccount:account delegate:self];
    NavigationViewController *loginNavigationController = [[NavigationViewController alloc] initWithRootViewController:loginViewController];
    
    [UniversalDevice displayModalViewController:loginNavigationController onController:appDelegate.window.rootViewController withCompletionBlock:nil];
}

- (void)authenticateOnPremiseAccount:(UserAccount *)account password:(NSString *)password completionBlock:(LoginAuthenticationCompletionBlock)completionBlock
{
    [self authenticateOnPremiseAccount:account username:account.username password:password completionBlock:completionBlock];
}

- (void)authenticateOnPremiseAccount:(UserAccount *)account username:(NSString *)username password:(NSString *)password completionBlock:(LoginAuthenticationCompletionBlock)completionBlock
{
    NSDictionary *sessionParameters = [@{kAlfrescoMetadataExtraction : @YES,
                                         kAlfrescoThumbnailCreation : @YES} mutableCopy];
    if (account.accountCertificate)
    {
        NSURLCredential *certificateCredential = [NSURLCredential credentialWithIdentity:account.accountCertificate.identityRef
                                                                            certificates:account.accountCertificate.certificateChain
                                                                             persistence:NSURLCredentialPersistenceForSession];
        sessionParameters = @{kAlfrescoMetadataExtraction : @YES,
                              kAlfrescoThumbnailCreation : @YES,
                              kAlfrescoConnectUsingClientSSLCertificate : @YES,
                              kAlfrescoClientCertificateCredentials : certificateCredential};
    }

    self.currentLoginURLString = [Utility serverURLStringFromAccount:account];
    self.currentLoginRequest = [AlfrescoRepositorySession connectWithUrl:[NSURL URLWithString:self.currentLoginURLString] username:username password:password parameters:sessionParameters completionBlock:^(id<AlfrescoSession> session, NSError *error) {
        if (session)
        {
            [UniversalDevice clearDetailViewController];
            
            self.currentLoginURLString = nil;
            self.currentLoginRequest = nil;
            
            account.paidAccount = [session.repositoryInfo.edition isEqualToString:kRepositoryEditionEnterprise];
            
            if (completionBlock != NULL)
            {
                completionBlock(YES, session, nil);
            }
        }
        else
        {
            if (completionBlock != NULL)
            {
                completionBlock(NO, nil, error);
            }
        }
    }];
}

- (void)showHUDOnView:(UIView *)view
{
    MBProgressHUD *progress = [[MBProgressHUD alloc] initWithView:view];
    progress.removeFromSuperViewOnHide = YES;
    progress.label.text = NSLocalizedString(@"login.hud.label", @"Connecting...");
    progress.detailsLabel.text = NSLocalizedString(@"login.hud.cancel.label", @"Tap To Cancel");
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tappedCancelLoginRequest:)];
    tap.numberOfTapsRequired = 1;
    tap.numberOfTouchesRequired = 1;
    [progress addGestureRecognizer:tap];
    
    [view addSubview:progress];
    [progress showAnimated:YES];
    
    if (self.progressHUD)
    {
        [self.progressHUD removeFromSuperview];
        self.progressHUD = nil;
    }
    
    self.progressHUD = progress;
}

- (void)tappedCancelLoginRequest:(UIGestureRecognizer *)gesture
{
    [self cancelLoginRequest];
}

- (void)hideHUD
{
    [self.progressHUD hideAnimated:YES];
    self.progressHUD = nil;
}

- (void)unauthorizedAccessNotificationReceived:(NSNotification *)notification
{
    // try logging again
    NSError *error = (NSError *)notification.object;
    
    if (error.code == kAlfrescoErrorCodeUnauthorisedAccess)
    {
        UserAccount *selectedAccount = [AccountManager sharedManager].selectedAccount;
        [self attemptLoginToAccount:selectedAccount networkId:selectedAccount.selectedNetworkId completionBlock:nil];
    }
}

- (void)cancelLoginRequest
{
    [self hideHUD];
    [self.currentLoginRequest cancel];
    self.didCancelLogin = YES;
    self.currentLoginRequest = nil;
    self.currentLoginURLString = nil;
}

- (void)reachabilityChanged:(NSNotification *)notification
{
    BOOL hasInternetConnection = [[ConnectivityManager sharedManager] hasInternetConnection];
    
    if(hasInternetConnection)
    {
        UserAccount *selectedAccount = [AccountManager sharedManager].selectedAccount;
        [self attemptLoginToAccount:selectedAccount networkId:selectedAccount.selectedNetworkId completionBlock:^(BOOL successful, id<AlfrescoSession> alfrescoSession, NSError *error) {
            if(successful && !self.completionBlockCalledFromLoginViewController)
            {
                AppDelegate *delegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
                delegate.mainMenuViewController.autoselectDefaultMenuOption = NO;
                [[NSNotificationCenter defaultCenter] postNotificationName:kAlfrescoSessionReceivedNotification object:alfrescoSession userInfo:nil];
            }
            else if (self.completionBlockCalledFromLoginViewController)
            {
                self.completionBlockCalledFromLoginViewController = NO;
            }
        }];
    }
}

- (void)tokenExpired:(NSNotification *)notification
{
    if([AccountManager sharedManager].selectedAccount)
    {
        [[LoginManager sharedManager] attemptLoginToAccount:[AccountManager sharedManager].selectedAccount networkId:[AccountManager sharedManager].selectedAccount.selectedNetworkId completionBlock:nil];
    }
}

#pragma mark - LoginViewControllerDelegate Functions

- (void)loginViewController:(LoginViewController *)loginViewController didPressRequestLoginToAccount:(UserAccount *)account username:(NSString *)username password:(NSString *)password
{
    [self showHUDOnView:loginViewController.view];
    [self authenticateOnPremiseAccount:account username:username password:password completionBlock:^(BOOL successful, id<AlfrescoSession> alfrescoSession, NSError *error) {
        [self hideHUD];
        if (successful)
        {
            self.sessionExpired = NO;
            
            account.username = username;
            account.password = password;
            [[AccountManager sharedManager] saveAccountsToKeychain];
            if (self.authenticationCompletionBlock != NULL)
            {
                self.completionBlockCalledFromLoginViewController = YES;
                self.authenticationCompletionBlock(YES, alfrescoSession, error);
            }
            [loginViewController dismissViewControllerAnimated:YES completion:nil];
            [[NSNotificationCenter defaultCenter] postNotificationName:kAlfrescoSessionReceivedNotification object:alfrescoSession userInfo:nil];
        }
        else
        {
            [loginViewController updateUIForFailedLogin];
            displayErrorMessage([ErrorDescriptions descriptionForError:error]);
        }
    }];
}

@end
