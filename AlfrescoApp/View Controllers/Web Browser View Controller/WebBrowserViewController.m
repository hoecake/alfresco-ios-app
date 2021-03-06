/*******************************************************************************
 * Copyright (C) 2005-2016 Alfresco Software Limited.
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
 
#import "WebBrowserViewController.h"
#import "ConnectivityManager.h"
#import "DismissCompletionProtocol.h"
#import "NJKWebViewProgress.h"
#import "NJKWebViewProgressView.h"

static CGFloat const kSpacingBetweenButtons = 22.0f;
static CGFloat const kProgressBarHeight = 2.0f;

@interface WebBrowserViewController () <UIWebViewDelegate, NJKWebViewProgressDelegate>

// Views
@property (nonatomic, weak) IBOutlet NSLayoutConstraint *toolbarHeightConstraint;
@property (nonatomic, weak) IBOutlet UIWebView *webView;
@property (nonatomic, weak) IBOutlet UIToolbar *toolBar;
@property (nonatomic, weak) IBOutlet UILabel *noInternetLabel;
@property (nonatomic, strong) NJKWebViewProgressView *progressView;
@property (nonatomic, strong) NJKWebViewProgress *progressProxy;
// Data Structure
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSURL *fallbackURL;
@property (nonatomic, strong) NSURL *errorURL;
@property (nonatomic, strong) NSString *initalTitle;
@property (nonatomic, assign) BOOL shouldHideToolbar;
// Buttons
@property (nonatomic, weak) UIBarButtonItem *backButton;
@property (nonatomic, weak) UIBarButtonItem *forwardButton;

@end

@implementation WebBrowserViewController

- (instancetype)initWithURLString:(NSString *)urlString initialFallbackURLString:(NSString *)fallbackURLString initialTitle:(NSString *)initialTitle errorLoadingURLString:(NSString *)errorURLString
{
    return [self initWithURL:[NSURL URLWithString:urlString] initialFallbackURL:[NSURL URLWithString:fallbackURLString] initialTitle:initialTitle errorLoadingURL:(errorURLString) ? [NSURL fileURLWithPath:errorURLString] : nil];
}

- (instancetype)initWithURL:(NSURL *)url initialFallbackURL:(NSURL *)fallbackURL initialTitle:(NSString *)initialTitle errorLoadingURL:(NSURL *)errorURL
{
    self = [self init];
    if (self)
    {
        self.url = url;
        self.fallbackURL = fallbackURL;
        self.initalTitle = initialTitle;
        self.errorURL = errorURL;
        
        if (url.isFileURL)
        {
            self.shouldHideToolbar = YES;
        }
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.title = self.initalTitle;
    
    self.noInternetLabel.text = NSLocalizedString(@"help.no.internet.message", @"No Internet Message");
    
    [self setupProgressView];
    
    NSMutableArray *webViewButtons = nil;
    if (!self.url.filePathURL)
    {
        UIBarButtonItem *backButton = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"ButtonBarArrowLeft.png"] style:UIBarButtonItemStylePlain target:self action:@selector(backButtonPressed:)];
        backButton.enabled = NO;
        UIBarButtonItem *fixedSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
        fixedSpace.width = kSpacingBetweenButtons;
        UIBarButtonItem *forwardButton = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"ButtonBarArrowRight.png"] style:UIBarButtonItemStylePlain target:self action:@selector(forwardButtonPressed:)];
        forwardButton.enabled = NO;
        
        webViewButtons = [NSMutableArray arrayWithObjects:backButton, fixedSpace, forwardButton, nil];
    }
    
    // dismiss button
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissHelp:)];
    
    if (self.toolBar)
    {
        // add spacer, followed by the dismiss button. Hmmm ...
        UIBarButtonItem *flexibleSpacer = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        [webViewButtons addObject:flexibleSpacer];
        [webViewButtons addObject:closeButton];
        
        self.toolBar.items = webViewButtons;
        
        self.backButton = self.toolBar.items[0];
        self.forwardButton = self.toolBar.items[2];
    }
    else
    {
        self.navigationItem.leftBarButtonItems = webViewButtons;
        
        self.backButton = self.navigationItem.leftBarButtonItems[0];
        self.forwardButton = self.navigationItem.leftBarButtonItems[2];
    }
    
    if (self.url.isFileURL || IS_IPAD)
    {
        self.navigationItem.rightBarButtonItem = closeButton;
    }
    
    if (self.shouldHideToolbar)
    {
        self.toolbarHeightConstraint.constant = 0;
    }
    
    // Make an initial HTTP request to check if the page is accessible
    [self initiateHTTPRequestToURL:self.url];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    [[AnalyticsManager sharedManager] trackScreenWithName:kAnalyticsViewHelp];
}

#pragma mark - Private Functions

- (void)initiateHTTPRequestToURL:(NSURL *)url
{
    [self showWebView];
    
    if ([[ConnectivityManager sharedManager] hasInternetConnection])
    {
        void (^processResponse)(NSURLResponse *) = ^(NSURLResponse *response) {
            if ([response isKindOfClass:[NSHTTPURLResponse class]])
            {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                NSInteger statusCode = httpResponse.statusCode;
                
                // If the page receives a 404, and is the initial request, redirect to the fallback URL, error URL or hide the webview
                if (statusCode == 404 && !self.webView.canGoBack)
                {
                    if (self.fallbackURL)
                    {
                        NSURLRequest *redirectURLRequest = [NSURLRequest requestWithURL:self.fallbackURL];
                        [self.webView loadRequest:redirectURLRequest];
                    }
                    else if (self.errorURL)
                    {
                        NSURLRequest *errorURLRequest = [NSURLRequest requestWithURL:self.errorURL];
                        [self.webView loadRequest:errorURLRequest];
                    }
                    else
                    {
                        [self hideWebView];
                    }
                }
                else
                {
                    [self makeInitialWebViewRequest];
                }
            }
        };
        
        NSURLRequest *httpRequest = [NSURLRequest requestWithURL:url];
        NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:nil delegateQueue:nil];
        NSURLSessionDataTask *urlSessionDataTask = [urlSession dataTaskWithRequest:httpRequest completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error)
            {
                [self hideWebView];
            }
            else
            {
                processResponse(response);
            }
        }];
        [urlSessionDataTask resume];
    }
    else if (self.errorURL)
    {
        NSURLRequest *request = [NSURLRequest requestWithURL:self.errorURL];
        [self.webView loadRequest:request];
    }
    else
    {
        [self hideWebView];
    }
}

- (void)makeInitialWebViewRequest
{
    [self showWebView];
    if ([[ConnectivityManager sharedManager] hasInternetConnection])
    {
        NSURLRequest *request = [NSURLRequest requestWithURL:self.url];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.webView loadRequest:request];
        });
    }
    else if (self.errorURL)
    {
        NSURLRequest *request = [NSURLRequest requestWithURL:self.errorURL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.webView loadRequest:request];
        });
    }
    else
    {
        [self hideWebView];
    }
}

- (void)backButtonPressed:(UIBarButtonItem *)buttonItem
{
    [self.webView goBack];
}

- (void)forwardButtonPressed:(UIBarButtonItem *)buttonItem
{
    [self.webView goForward];
}

- (void)dismissHelp:(UIBarButtonItem *)buttonItem
{
    [self dismissViewControllerAnimated:YES completion:self.dismissCompletionBlock];
}

- (void)updateButtons
{
    self.backButton.enabled = self.webView.canGoBack;
    self.forwardButton.enabled = self.webView.canGoForward;
}

- (void)showWebView
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.webView.hidden = NO;
        [self updateButtons];
    });
}

- (void)hideWebView
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.webView.hidden = YES;
        self.backButton.enabled = NO;
        self.forwardButton.enabled = NO;
    });
}

- (void)setupProgressView
{
    self.progressProxy = [[NJKWebViewProgress alloc] init];
    self.webView.delegate = self.progressProxy;
    self.progressProxy.webViewProxyDelegate = self;
    self.progressProxy.progressDelegate = self;
    
    CGRect navigationBarBounds = self.navigationController.navigationBar.bounds;
    CGRect progressBarFrame = CGRectMake(0,
                                         navigationBarBounds.size.height - kProgressBarHeight,
                                         navigationBarBounds.size.width,
                                         kProgressBarHeight);
    self.progressView = [[NJKWebViewProgressView alloc] initWithFrame:progressBarFrame];
    self.progressView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    
    [self.navigationController.navigationBar addSubview:self.progressView];
}

#pragma mark - UIWebViewDelegate Functions

- (void)webViewDidFinishLoad:(UIWebView *)webView
{
    if (!self.url.isFileURL)
    {
        NSString *title = [webView stringByEvaluatingJavaScriptFromString:@"document.title"];
        self.navigationItem.title = title;
    }

    [self updateButtons];
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error
{
    if(error.code != -999)
    {
        [self hideWebView];
    }
}

#pragma mark - NJKWebViewProgressDelegate Methods

- (void)webViewProgress:(NJKWebViewProgress *)webViewProgress updateProgress:(float)progress
{
    self.progressView.progress = progress;
}

@end
