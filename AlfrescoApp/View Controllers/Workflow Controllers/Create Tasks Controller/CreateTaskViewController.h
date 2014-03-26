//
//  CreateTaskViewController.h
//  AlfrescoApp
//
//  Created by Mohamad Saeedi on 20/03/2014.
//  Copyright (c) 2014 Alfresco. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "WorkflowTypes.h"

typedef NS_ENUM(NSUInteger, CreateTaskRowType)
{
    CreateTaskRowTypeTitle,
    CreateTaskRowTypeDueDate,
    CreateTaskRowTypeAssignees,
    CreateTaskRowTypeApprovers,
    CreateTaskRowTypeAttachments,
    CreateTaskRowTypePriority,
    CreateTaskRowTypeEmailNotification
};

@interface CreateTaskViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>

- (instancetype)initWithSession:(id<AlfrescoSession>)session workflowType:(WorkflowType)workflowType;

@end
