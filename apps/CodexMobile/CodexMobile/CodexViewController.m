#import "CodexViewController.h"
#import <QuartzCore/QuartzCore.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <math.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/processor_info.h>
#import <signal.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/resource.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSString * const CodexCurrentProjectKey = @"CodexMobileCurrentProject";
static NSString * const CodexStartedProjectsKey = @"CodexMobileStartedProjects";

@interface CMMeterView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIView *trackView;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) NSLayoutConstraint *fillWidthConstraint;
@property (nonatomic) CGFloat currentPercent;
- (instancetype)initWithTitle:(NSString *)title color:(UIColor *)color;
- (void)setPercent:(CGFloat)percent;
@end

@implementation CMMeterView

- (instancetype)initWithTitle:(NSString *)title color:(UIColor *)color {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = NO;

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = title;
    self.titleLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
    self.titleLabel.font = [UIFont systemFontOfSize:8.5 weight:UIFontWeightSemibold];
    [self addSubview:self.titleLabel];

    self.valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.valueLabel.text = @"--%";
    self.valueLabel.textAlignment = NSTextAlignmentRight;
    self.valueLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    self.valueLabel.font = [UIFont systemFontOfSize:8.5 weight:UIFontWeightSemibold];
    self.valueLabel.adjustsFontSizeToFitWidth = YES;
    self.valueLabel.minimumScaleFactor = 0.7;
    [self addSubview:self.valueLabel];

    self.trackView = [[UIView alloc] initWithFrame:CGRectZero];
    self.trackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.trackView.backgroundColor = [UIColor colorWithWhite:0.20 alpha:1.0];
    self.trackView.layer.cornerRadius = 2.0;
    self.trackView.clipsToBounds = YES;
    [self addSubview:self.trackView];

    self.fillView = [[UIView alloc] initWithFrame:CGRectZero];
    self.fillView.translatesAutoresizingMaskIntoConstraints = NO;
    self.fillView.backgroundColor = color;
    [self.trackView addSubview:self.fillView];

    self.fillWidthConstraint = [self.fillView.widthAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.titleLabel.widthAnchor constraintEqualToConstant:26],
        [self.titleLabel.heightAnchor constraintEqualToConstant:10],

        [self.valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.valueLabel.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.valueLabel.widthAnchor constraintEqualToConstant:30],
        [self.valueLabel.heightAnchor constraintEqualToConstant:10],

        [self.trackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.trackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.trackView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.trackView.heightAnchor constraintEqualToConstant:4],

        [self.fillView.leadingAnchor constraintEqualToAnchor:self.trackView.leadingAnchor],
        [self.fillView.topAnchor constraintEqualToAnchor:self.trackView.topAnchor],
        [self.fillView.bottomAnchor constraintEqualToAnchor:self.trackView.bottomAnchor],
        self.fillWidthConstraint
    ]];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self applyCurrentPercent];
}

- (void)setPercent:(CGFloat)percent {
    self.currentPercent = MIN(1.0, MAX(0.0, percent));
    [self applyCurrentPercent];
}

- (void)applyCurrentPercent {
    self.valueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)lrint(self.currentPercent * 100.0)];
    CGFloat width = CGRectGetWidth(self.trackView.bounds);
    self.fillWidthConstraint.constant = width * self.currentPercent;
}

@end

@interface CMMenuAction : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL destructive;
@property (nonatomic, copy) void (^handler)(void);
+ (instancetype)actionWithTitle:(NSString *)title destructive:(BOOL)destructive handler:(void (^)(void))handler;
@end

@implementation CMMenuAction

+ (instancetype)actionWithTitle:(NSString *)title destructive:(BOOL)destructive handler:(void (^)(void))handler {
    CMMenuAction *action = [[CMMenuAction alloc] init];
    action.title = title ?: @"";
    action.destructive = destructive;
    action.handler = handler;
    return action;
}

@end

typedef NS_ENUM(NSInteger, CMChatRole) {
    CMChatRoleSystem = 0,
    CMChatRoleUser,
    CMChatRoleAssistant,
    CMChatRoleActivity
};

typedef NS_ENUM(NSInteger, CMChatBlockKind) {
    CMChatBlockKindText = 0,
    CMChatBlockKindThinking,
    CMChatBlockKindCommandList,
    CMChatBlockKindFileChangeList,
    CMChatBlockKindCode,
    CMChatBlockKindBuildResult
};

@interface CMChatBlock : NSObject
@property (nonatomic) CMChatBlockKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSArray<NSString *> *items;
+ (instancetype)blockWithKind:(CMChatBlockKind)kind title:(NSString *)title text:(NSString *)text items:(NSArray<NSString *> *)items;
+ (NSArray<CMChatBlock *> *)textBlocksFromMarkdown:(NSString *)text;
- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)blockFromDictionary:(NSDictionary *)dictionary;
- (NSString *)displayText;
@end

@implementation CMChatBlock

+ (instancetype)blockWithKind:(CMChatBlockKind)kind title:(NSString *)title text:(NSString *)text items:(NSArray<NSString *> *)items {
    CMChatBlock *block = [[CMChatBlock alloc] init];
    block.kind = kind;
    block.title = title ?: @"";
    block.text = text ?: @"";
    block.items = items ?: @[];
    return block;
}

+ (NSArray<CMChatBlock *> *)textBlocksFromMarkdown:(NSString *)text {
    if (!text.length) return @[[CMChatBlock blockWithKind:CMChatBlockKindText title:nil text:@"" items:nil]];
    NSMutableArray<CMChatBlock *> *blocks = [NSMutableArray array];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *buffer = [NSMutableArray array];
    NSMutableArray<NSString *> *codeBuffer = [NSMutableArray array];
    BOOL inCode = NO;

    void (^flushText)(void) = ^{
        if (!buffer.count) return;
        [blocks addObject:[CMChatBlock blockWithKind:CMChatBlockKindText title:nil text:[buffer componentsJoinedByString:@"\n"] items:nil]];
        [buffer removeAllObjects];
    };
    void (^flushCode)(void) = ^{
        [blocks addObject:[CMChatBlock blockWithKind:CMChatBlockKindCode title:@"Code" text:[codeBuffer componentsJoinedByString:@"\n"] items:nil]];
        [codeBuffer removeAllObjects];
    };

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"```"]) {
            if (inCode) {
                flushCode();
            } else {
                flushText();
            }
            inCode = !inCode;
            continue;
        }
        if (inCode) [codeBuffer addObject:line ?: @""];
        else [buffer addObject:line ?: @""];
    }
    if (inCode) flushCode();
    flushText();
    return blocks;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"kind": @(self.kind),
        @"title": self.title ?: @"",
        @"text": self.text ?: @"",
        @"items": self.items ?: @[]
    };
}

+ (instancetype)blockFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    CMChatBlockKind kind = [dictionary[@"kind"] integerValue];
    NSString *title = [dictionary[@"title"] isKindOfClass:[NSString class]] ? dictionary[@"title"] : @"";
    NSString *text = [dictionary[@"text"] isKindOfClass:[NSString class]] ? dictionary[@"text"] : @"";
    NSArray *rawItems = [dictionary[@"items"] isKindOfClass:[NSArray class]] ? dictionary[@"items"] : @[];
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (id item in rawItems) {
        if ([item isKindOfClass:[NSString class]]) [items addObject:item];
    }
    return [CMChatBlock blockWithKind:kind title:title text:text items:items];
}

- (NSString *)displayText {
    if (self.kind == CMChatBlockKindCode) {
        return [NSString stringWithFormat:@"```\n%@\n```", self.text ?: @""];
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (self.title.length) [lines addObject:self.title];
    if (self.text.length) [lines addObject:self.text];
    for (NSString *item in self.items) {
        if (!item.length) continue;
        if (self.kind == CMChatBlockKindCommandList) {
            [lines addObject:[NSString stringWithFormat:@"`%@`", item]];
        } else {
            [lines addObject:[@"- " stringByAppendingString:item]];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end

@interface CMChatMessage : NSObject
@property (nonatomic) CMChatRole role;
@property (nonatomic, strong) NSMutableArray<CMChatBlock *> *blocks;
+ (instancetype)messageWithRole:(CMChatRole)role text:(NSString *)text;
+ (instancetype)activityMessage;
+ (instancetype)messageFromDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;
- (NSString *)roleName;
- (NSString *)displayText;
- (void)setMarkdownText:(NSString *)text;
- (void)setSingleText:(NSString *)text;
@end

@implementation CMChatMessage

+ (instancetype)messageWithRole:(CMChatRole)role text:(NSString *)text {
    CMChatMessage *message = [[CMChatMessage alloc] init];
    message.role = role;
    message.blocks = [NSMutableArray array];
    if (role == CMChatRoleAssistant) [message setMarkdownText:text ?: @""];
    else [message setSingleText:text ?: @""];
    return message;
}

+ (instancetype)activityMessage {
    CMChatMessage *message = [CMChatMessage messageWithRole:CMChatRoleActivity text:@""];
    message.blocks = [NSMutableArray array];
    return message;
}

+ (instancetype)messageFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    NSString *roleText = [dictionary[@"role"] isKindOfClass:[NSString class]] ? dictionary[@"role"] : @"Assistant";
    CMChatRole role = CMChatRoleAssistant;
    if ([roleText isEqualToString:@"You"]) role = CMChatRoleUser;
    else if ([roleText isEqualToString:@"System"]) role = CMChatRoleSystem;
    else if ([roleText isEqualToString:@"Activity"]) role = CMChatRoleActivity;

    CMChatMessage *message = [[CMChatMessage alloc] init];
    message.role = role;
    message.blocks = [NSMutableArray array];
    NSArray *rawBlocks = [dictionary[@"blocks"] isKindOfClass:[NSArray class]] ? dictionary[@"blocks"] : nil;
    for (NSDictionary *rawBlock in rawBlocks) {
        CMChatBlock *block = [CMChatBlock blockFromDictionary:rawBlock];
        if (block) [message.blocks addObject:block];
    }
    if (!message.blocks.count) {
        NSString *text = [dictionary[@"text"] isKindOfClass:[NSString class]] ? dictionary[@"text"] : @"";
        if (role == CMChatRoleAssistant) [message setMarkdownText:text];
        else [message setSingleText:text];
    }
    return message;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *blocks = [NSMutableArray arrayWithCapacity:self.blocks.count];
    for (CMChatBlock *block in self.blocks) [blocks addObject:[block dictionaryRepresentation]];
    return @{
        @"role": [self roleName],
        @"text": [self displayText],
        @"blocks": blocks
    };
}

- (NSString *)roleName {
    switch (self.role) {
        case CMChatRoleSystem: return @"System";
        case CMChatRoleUser: return @"You";
        case CMChatRoleActivity: return @"Activity";
        case CMChatRoleAssistant:
        default: return @"Assistant";
    }
}

- (NSString *)displayText {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (CMChatBlock *block in self.blocks) {
        NSString *text = [block displayText];
        if (text.length) [parts addObject:text];
    }
    return [parts componentsJoinedByString:@"\n\n"];
}

- (void)setMarkdownText:(NSString *)text {
    self.blocks = [[CMChatBlock textBlocksFromMarkdown:text ?: @""] mutableCopy];
}

- (void)setSingleText:(NSString *)text {
    self.blocks = [NSMutableArray arrayWithObject:[CMChatBlock blockWithKind:CMChatBlockKindText title:nil text:text ?: @"" items:nil]];
}

@end

typedef NS_ENUM(NSInteger, CMCodexEventKind) {
    CMCodexEventKindUnknown = 0,
    CMCodexEventKindStreamDelta,
    CMCodexEventKindThreadStarted,
    CMCodexEventKindTurnStarted,
    CMCodexEventKindTurnCompleted,
    CMCodexEventKindError,
    CMCodexEventKindAgentMessage,
    CMCodexEventKindReasoning,
    CMCodexEventKindCommandExecution,
    CMCodexEventKindFileChange,
    CMCodexEventKindWebSearch,
    CMCodexEventKindMCPToolCall,
    CMCodexEventKindTodoList
};

@interface CMCodexEvent : NSObject
@property (nonatomic) CMCodexEventKind kind;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL completed;
@property (nonatomic, copy) NSString *delta;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *command;
@property (nonatomic, strong) NSArray *changes;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSString *server;
@property (nonatomic, copy) NSString *tool;
@property (nonatomic, strong) NSArray<NSDictionary *> *todoItems;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, strong) NSNumber *exitCode;
+ (instancetype)eventWithDictionary:(NSDictionary *)dictionary;
+ (NSString *)stringValueFromObject:(id)object fallback:(NSString *)fallback;
+ (NSString *)commandDisplayFromObject:(id)object;
@end

@implementation CMCodexEvent

+ (instancetype)eventWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    CMCodexEvent *event = [[CMCodexEvent alloc] init];
    event.kind = CMCodexEventKindUnknown;

    NSString *type = [dictionary[@"type"] isKindOfClass:[NSString class]] ? dictionary[@"type"] : @"";
    event.started = [type isEqualToString:@"item.started"];
    event.completed = [type isEqualToString:@"item.completed"];
    event.delta = [self stringValueFromObject:dictionary[@"delta"] fallback:@""];
    if (!event.delta.length) event.delta = [self stringValueFromObject:dictionary[@"text_delta"] fallback:@""];
    if (!event.delta.length) event.delta = [self stringValueFromObject:dictionary[@"content_delta"] fallback:@""];
    if (event.delta.length && [type rangeOfString:@"delta" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        event.kind = CMCodexEventKindStreamDelta;
        return event;
    }

    if ([type isEqualToString:@"thread.started"]) event.kind = CMCodexEventKindThreadStarted;
    else if ([type isEqualToString:@"turn.started"]) event.kind = CMCodexEventKindTurnStarted;
    else if ([type isEqualToString:@"turn.completed"]) event.kind = CMCodexEventKindTurnCompleted;
    else if ([type isEqualToString:@"turn.failed"] || [type isEqualToString:@"error"]) {
        event.kind = CMCodexEventKindError;
        NSDictionary *error = [type isEqualToString:@"turn.failed"] && [dictionary[@"error"] isKindOfClass:[NSDictionary class]] ? dictionary[@"error"] : dictionary;
        event.text = [self stringValueFromObject:error[@"message"] fallback:@"turn failed"];
    }

    NSDictionary *item = [dictionary[@"item"] isKindOfClass:[NSDictionary class]] ? dictionary[@"item"] : nil;
    NSString *itemType = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"";
    if (!itemType.length) return event;

    if ([itemType isEqualToString:@"agent_message"]) {
        event.kind = CMCodexEventKindAgentMessage;
        event.delta = [self stringValueFromObject:item[@"delta"] fallback:@""];
        if (!event.delta.length) event.delta = [self stringValueFromObject:item[@"text_delta"] fallback:@""];
        event.text = [self stringValueFromObject:item[@"text"] fallback:@""];
    } else if ([itemType isEqualToString:@"reasoning"]) {
        event.kind = CMCodexEventKindReasoning;
        event.text = [self stringValueFromObject:item[@"text"] fallback:@""];
    } else if ([itemType isEqualToString:@"command_execution"]) {
        event.kind = CMCodexEventKindCommandExecution;
        event.command = [self commandDisplayFromObject:item[@"command"]];
        if (!event.command.length) event.command = [self stringValueFromObject:item[@"cmd"] fallback:@""];
        event.status = [self stringValueFromObject:item[@"status"] fallback:@"completed"];
        event.exitCode = [item[@"exit_code"] isKindOfClass:[NSNumber class]] ? item[@"exit_code"] : nil;
    } else if ([itemType isEqualToString:@"file_change"]) {
        event.kind = CMCodexEventKindFileChange;
        event.changes = [item[@"changes"] isKindOfClass:[NSArray class]] ? item[@"changes"] : @[];
    } else if ([itemType isEqualToString:@"web_search"]) {
        event.kind = CMCodexEventKindWebSearch;
        event.query = [self stringValueFromObject:item[@"query"] fallback:@"web"];
    } else if ([itemType isEqualToString:@"mcp_tool_call"]) {
        event.kind = CMCodexEventKindMCPToolCall;
        event.server = [self stringValueFromObject:item[@"server"] fallback:@"tool"];
        event.tool = [self stringValueFromObject:item[@"tool"] fallback:@""];
    } else if ([itemType isEqualToString:@"todo_list"]) {
        event.kind = CMCodexEventKindTodoList;
        event.todoItems = [item[@"items"] isKindOfClass:[NSArray class]] ? item[@"items"] : @[];
    } else if ([itemType isEqualToString:@"error"]) {
        event.kind = CMCodexEventKindError;
        event.text = [self stringValueFromObject:item[@"message"] fallback:@"unknown"];
    }
    return event;
}

+ (NSString *)stringValueFromObject:(id)object fallback:(NSString *)fallback {
    if ([object isKindOfClass:[NSString class]]) return object;
    if ([object isKindOfClass:[NSNumber class]]) return [object stringValue];
    return fallback ?: @"";
}

+ (NSString *)commandDisplayFromObject:(id)object {
    if ([object isKindOfClass:[NSString class]]) return object;
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in (NSArray *)object) {
            NSString *part = [self stringValueFromObject:item fallback:@""];
            if (part.length) [parts addObject:part];
        }
        return [parts componentsJoinedByString:@" "];
    }
    return [self stringValueFromObject:object fallback:@""];
}

@end

@interface CMChatCell : UITableViewCell
@property (nonatomic, strong) UIView *bubbleView;
@property (nonatomic, strong) UILabel *roleLabel;
@property (nonatomic, strong) UILabel *bodyLabel;
@property (nonatomic, strong) NSLayoutConstraint *leadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *trailingConstraint;
- (void)configureWithMessage:(CMChatMessage *)message empty:(BOOL)empty;
@end

@implementation CMChatCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];

    self.bubbleView = [[UIView alloc] initWithFrame:CGRectZero];
    self.bubbleView.translatesAutoresizingMaskIntoConstraints = NO;
    self.bubbleView.layer.cornerRadius = 13.0;
    self.bubbleView.layer.borderWidth = 1.0;
    [self.contentView addSubview:self.bubbleView];

    self.roleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.roleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.roleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [self.bubbleView addSubview:self.roleLabel];

    self.bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bodyLabel.numberOfLines = 0;
    self.bodyLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self.bubbleView addSubview:self.bodyLabel];

    self.leadingConstraint = [self.bubbleView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14];
    self.trailingConstraint = [self.bubbleView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14];

    [NSLayoutConstraint activateConstraints:@[
        [self.bubbleView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [self.bubbleView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        [self.bubbleView.widthAnchor constraintLessThanOrEqualToAnchor:self.contentView.widthAnchor multiplier:0.88],

        [self.roleLabel.leadingAnchor constraintEqualToAnchor:self.bubbleView.leadingAnchor constant:12],
        [self.roleLabel.trailingAnchor constraintEqualToAnchor:self.bubbleView.trailingAnchor constant:-12],
        [self.roleLabel.topAnchor constraintEqualToAnchor:self.bubbleView.topAnchor constant:10],

        [self.bodyLabel.leadingAnchor constraintEqualToAnchor:self.bubbleView.leadingAnchor constant:12],
        [self.bodyLabel.trailingAnchor constraintEqualToAnchor:self.bubbleView.trailingAnchor constant:-12],
        [self.bodyLabel.topAnchor constraintEqualToAnchor:self.roleLabel.bottomAnchor constant:5],
        [self.bodyLabel.bottomAnchor constraintEqualToAnchor:self.bubbleView.bottomAnchor constant:-11]
    ]];
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.leadingConstraint.active = NO;
    self.trailingConstraint.active = NO;
    self.bodyLabel.text = nil;
    self.bodyLabel.attributedText = nil;
}

- (void)configureWithMessage:(CMChatMessage *)message empty:(BOOL)empty {
    CMChatRole role = message ? message.role : CMChatRoleSystem;
    BOOL isUser = role == CMChatRoleUser;
    BOOL isAssistant = role == CMChatRoleAssistant;
    BOOL isActivity = role == CMChatRoleActivity;
    BOOL isSystem = empty || role == CMChatRoleSystem;
    NSString *text = message ? [message displayText] : @"What can I help you build, fix, or understand today?";

    self.roleLabel.text = (isSystem || isAssistant || isActivity) ? @"Codex" : [message roleName];
    self.bodyLabel.font = isActivity ? [UIFont systemFontOfSize:14 weight:UIFontWeightRegular] : [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];

    UIColor *bodyColor = [UIColor colorWithWhite:0.93 alpha:1.0];
    if (isSystem) {
        self.leadingConstraint.active = YES;
        self.bubbleView.backgroundColor = [UIColor clearColor];
        self.bubbleView.layer.borderColor = [UIColor clearColor].CGColor;
        self.roleLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        bodyColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    } else if (isActivity) {
        self.leadingConstraint.active = YES;
        self.bubbleView.backgroundColor = [UIColor colorWithRed:0.105 green:0.110 blue:0.122 alpha:1.0];
        self.bubbleView.layer.borderColor = [UIColor colorWithWhite:0.20 alpha:1.0].CGColor;
        self.roleLabel.textColor = [UIColor colorWithWhite:0.80 alpha:1.0];
        bodyColor = [UIColor colorWithWhite:0.84 alpha:1.0];
    } else if (isUser) {
        self.trailingConstraint.active = YES;
        self.bubbleView.backgroundColor = [UIColor colorWithRed:0.155 green:0.166 blue:0.190 alpha:1.0];
        self.bubbleView.layer.borderColor = [UIColor colorWithWhite:0.30 alpha:1.0].CGColor;
        self.roleLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
        bodyColor = [UIColor whiteColor];
    } else {
        self.leadingConstraint.active = YES;
        self.bubbleView.backgroundColor = [UIColor colorWithRed:0.070 green:0.076 blue:0.090 alpha:1.0];
        self.bubbleView.layer.borderColor = [UIColor colorWithWhite:0.16 alpha:1.0].CGColor;
        self.roleLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        bodyColor = [UIColor colorWithWhite:0.93 alpha:1.0];
    }
    self.bodyLabel.textColor = bodyColor;
    if (isUser) {
        self.bodyLabel.text = text ?: @"";
    } else {
        self.bodyLabel.attributedText = [self attributedMarkdownString:text ?: @"" baseColor:bodyColor];
    }
}

- (NSAttributedString *)attributedMarkdownString:(NSString *)text baseColor:(UIColor *)baseColor {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL inCodeBlock = NO;

    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i] ?: @"";
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"```"]) {
            inCodeBlock = !inCodeBlock;
            continue;
        }

        NSAttributedString *rendered = nil;
        if (inCodeBlock) {
            rendered = [self attributedCodeLine:line baseColor:baseColor];
        } else if ([self isImageMarkdownLine:line]) {
            rendered = [self attributedImageMarkdownLine:line baseColor:baseColor];
        } else {
            rendered = [self attributedMarkdownLine:line baseColor:baseColor];
        }
        [result appendAttributedString:rendered];
        if (i + 1 < lines.count) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:[self baseTextAttributesWithColor:baseColor font:[UIFont systemFontOfSize:15 weight:UIFontWeightRegular]]]];
        }
    }
    return result;
}

- (NSDictionary *)baseTextAttributesWithColor:(UIColor *)color font:(UIFont *)font {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 3.0;
    style.paragraphSpacing = 5.0;
    return @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: style
    };
}

- (NSAttributedString *)attributedCodeLine:(NSString *)line baseColor:(UIColor *)baseColor {
    UIFont *font = [UIFont fontWithName:@"Menlo" size:13.0] ?: [UIFont systemFontOfSize:13.0];
    NSMutableDictionary *attrs = [[self baseTextAttributesWithColor:[UIColor colorWithWhite:0.90 alpha:1.0] font:font] mutableCopy];
    attrs[NSBackgroundColorAttributeName] = [UIColor colorWithRed:0.125 green:0.130 blue:0.140 alpha:1.0];
    return [[NSAttributedString alloc] initWithString:line attributes:attrs];
}

- (BOOL)isImageMarkdownLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^!\\[[^\\]]*\\]\\([^\\)]+\\)$" options:0 error:nil];
    return [regex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)] != nil;
}

- (NSAttributedString *)attributedImageMarkdownLine:(NSString *)line baseColor:(UIColor *)baseColor {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^!\\[([^\\]]*)\\]\\(([^\\)]+)\\)$" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    if (!match || match.numberOfRanges < 3) return [self attributedMarkdownLine:line baseColor:baseColor];

    NSString *alt = [trimmed substringWithRange:[match rangeAtIndex:1]];
    NSString *rawPath = [trimmed substringWithRange:[match rangeAtIndex:2]];
    NSString *path = [rawPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    path = [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'"]];
    path = path.stringByRemovingPercentEncoding ?: path;
    if ([path hasPrefix:@"file://"]) {
        NSURL *url = [NSURL URLWithString:path];
        path = url.path ?: path;
    }

    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image) return [self attributedMarkdownLine:line baseColor:baseColor];

    CGFloat maxWidth = 286.0;
    CGFloat maxHeight = 360.0;
    CGFloat scale = MIN(maxWidth / MAX(image.size.width, 1.0), maxHeight / MAX(image.size.height, 1.0));
    scale = MIN(scale, 1.0);

    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = image;
    attachment.bounds = CGRectMake(0, 0, floor(image.size.width * scale), floor(image.size.height * scale));

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    if (alt.length) {
        NSDictionary *captionAttrs = [self baseTextAttributesWithColor:[UIColor colorWithWhite:0.68 alpha:1.0]
                                                                  font:[UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium]];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@", alt] attributes:captionAttrs]];
    }
    return result;
}

- (NSAttributedString *)attributedMarkdownLine:(NSString *)line baseColor:(UIColor *)baseColor {
    NSString *working = line ?: @"";
    UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    UIColor *color = baseColor;

    NSRegularExpression *headingRegex = [NSRegularExpression regularExpressionWithPattern:@"^(#{1,3})\\s+(.+)$" options:0 error:nil];
    NSTextCheckingResult *heading = [headingRegex firstMatchInString:working options:0 range:NSMakeRange(0, working.length)];
    if (heading.numberOfRanges == 3) {
        NSString *marks = [working substringWithRange:[heading rangeAtIndex:1]];
        working = [working substringWithRange:[heading rangeAtIndex:2]];
        CGFloat size = marks.length == 1 ? 20.0 : (marks.length == 2 ? 17.5 : 16.0);
        font = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
        color = [UIColor whiteColor];
    } else {
        NSRegularExpression *bulletRegex = [NSRegularExpression regularExpressionWithPattern:@"^\\s*[-*+]\\s+(.+)$" options:0 error:nil];
        NSTextCheckingResult *bullet = [bulletRegex firstMatchInString:working options:0 range:NSMakeRange(0, working.length)];
        if (bullet.numberOfRanges == 2) working = [@"- " stringByAppendingString:[working substringWithRange:[bullet rangeAtIndex:1]]];
    }

    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:working attributes:[self baseTextAttributesWithColor:color font:font]];
    [self applyInlineMarkdownToString:attributed baseColor:color baseFont:font];
    return attributed;
}

- (void)applyInlineMarkdownToString:(NSMutableAttributedString *)string baseColor:(UIColor *)baseColor baseFont:(UIFont *)baseFont {
    [self replaceMarkdownPattern:@"\\[([^\\]]+)\\]\\(([^\\)]+)\\)" inString:string group:1 attributes:@{
        NSForegroundColorAttributeName: [UIColor colorWithRed:0.50 green:0.72 blue:1.0 alpha:1.0],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
    }];
    UIFont *codeFont = [UIFont fontWithName:@"Menlo" size:13.0] ?: [UIFont systemFontOfSize:13.0];
    [self replaceMarkdownPattern:@"`([^`]+)`" inString:string group:1 attributes:@{
        NSFontAttributeName: codeFont,
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.94 alpha:1.0],
        NSBackgroundColorAttributeName: [UIColor colorWithRed:0.150 green:0.155 blue:0.168 alpha:1.0]
    }];
    [self replaceMarkdownPattern:@"\\*\\*([^*]+)\\*\\*" inString:string group:1 attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:baseFont.pointSize weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: baseColor
    }];
    [self replaceMarkdownPattern:@"__([^_]+)__" inString:string group:1 attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:baseFont.pointSize weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: baseColor
    }];
    [self replaceMarkdownPattern:@"_([^_\\n]+)_" inString:string group:1 attributes:@{
        NSFontAttributeName: [UIFont italicSystemFontOfSize:baseFont.pointSize],
        NSForegroundColorAttributeName: baseColor
    }];
}

- (void)replaceMarkdownPattern:(NSString *)pattern
                      inString:(NSMutableAttributedString *)string
                         group:(NSUInteger)group
                    attributes:(NSDictionary *)attributes {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:string.string options:0 range:NSMakeRange(0, string.length)];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        if (match.numberOfRanges <= group) continue;
        NSRange contentRange = [match rangeAtIndex:group];
        if (contentRange.location == NSNotFound) continue;
        NSString *replacement = [string.string substringWithRange:contentRange];
        NSMutableAttributedString *replacementText = [[NSMutableAttributedString alloc] initWithString:replacement attributes:nil];
        NSDictionary *baseAttrs = [string attributesAtIndex:match.range.location effectiveRange:nil];
        [replacementText addAttributes:baseAttrs range:NSMakeRange(0, replacementText.length)];
        [replacementText addAttributes:attributes range:NSMakeRange(0, replacementText.length)];
        [string replaceCharactersInRange:match.range withAttributedString:replacementText];
    }
}

@end

static CGFloat const CMComposerMinTextHeight = 38.0;
static CGFloat const CMComposerMaxTextHeight = 96.0;
static CGFloat const CMComposerBasePanelHeight = 112.0;
static CGFloat const CMComposerBaseViewHeight = 78.0;

@interface CodexViewController () <UITableViewDataSource, UITableViewDelegate, UITextViewDelegate>

@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *metricsContainer;
@property (nonatomic, strong) CMMeterView *cpuMeter;
@property (nonatomic, strong) CMMeterView *ramMeter;
@property (nonatomic, strong) CMMeterView *diskMeter;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIButton *terminalButton;

@property (nonatomic, strong) UITableView *chatTable;
@property (nonatomic, strong) UITableView *filesTable;
@property (nonatomic, strong) UITextView *terminalView;

@property (nonatomic, strong) UIView *bottomPanel;
@property (nonatomic, strong) UIView *composerView;
@property (nonatomic, strong) UIView *bottomMenuBar;
@property (nonatomic, strong) UIView *terminalToolbar;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UITextView *composerTextView;
@property (nonatomic, strong) UILabel *composerPlaceholderLabel;
@property (nonatomic, strong) UIButton *plusButton;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) UIButton *accessButton;
@property (nonatomic, strong) UIButton *modelButton;
@property (nonatomic, strong) UIButton *sessionsButton;
@property (nonatomic, strong) UIButton *historyButton;
@property (nonatomic, strong) UIButton *terminalCopyButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIControl *menuOverlayView;
@property (nonatomic, strong) NSArray<CMMenuAction *> *activeMenuActions;
@property (nonatomic, strong) NSLayoutConstraint *bottomPanelBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *bottomPanelHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *composerViewHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *composerTextViewHeightConstraint;

@property (nonatomic, strong) NSMutableArray<CMChatMessage *> *messages;
@property (nonatomic, strong) NSArray<NSDictionary *> *files;
@property (nonatomic, strong) NSArray<NSDictionary *> *appLibrary;
@property (nonatomic, strong) NSMutableArray<NSString *> *projects;
@property (nonatomic, strong) NSMutableSet<NSString *> *startedProjects;

@property (nonatomic, copy) NSString *documentsPath;
@property (nonatomic, copy) NSString *projectsRootPath;
@property (nonatomic, copy) NSString *workspacePath;
@property (nonatomic, copy) NSString *currentProjectName;
@property (nonatomic, copy) NSString *codexPath;
@property (nonatomic, copy) NSString *probePath;
@property (nonatomic, copy) NSString *appBuilderPath;
@property (nonatomic, copy) NSString *appBuilderInstructionsPath;
@property (nonatomic, copy) NSString *lastDeviceURL;
@property (nonatomic, copy) NSString *lastDeviceCode;
@property (nonatomic, copy) NSString *selectedModelName;
@property (nonatomic, copy) NSString *selectedReasoningEffort;
@property (nonatomic, copy) NSString *selectedReasoningLabel;
@property (nonatomic, copy) NSString *activeBuilderAppName;
@property (nonatomic, copy) NSString *activeBuilderBundleID;
@property (nonatomic, copy) NSString *activeBuilderLogPath;
@property (nonatomic) pid_t runningPid;
@property (nonatomic) NSInteger activeAssistantIndex;
@property (nonatomic) NSInteger activeActivityIndex;
@property (nonatomic) BOOL activeRunIsChat;
@property (nonatomic) BOOL activeRunIsBuilder;
@property (nonatomic) BOOL activeAssistantHasFinalMessage;
@property (nonatomic, strong) NSMutableString *jsonLineBuffer;
@property (nonatomic, strong) NSMutableString *activeAssistantText;
@property (nonatomic, copy) NSString *pendingRevealText;
@property (nonatomic) NSUInteger pendingRevealIndex;
@property (nonatomic, strong) NSMutableArray<NSString *> *activeActivityLines;
@property (nonatomic, strong) NSMutableArray<NSString *> *activeCommandLines;
@property (nonatomic, strong) NSMutableArray<NSString *> *activeChangedFiles;
@property (nonatomic) BOOL activeCommandFailed;
@property (nonatomic, strong) NSDate *activeTurnStartDate;
@property (nonatomic, strong) NSTimer *workingTimer;
@property (nonatomic, strong) NSTimer *revealTimer;
@property (nonatomic, strong) NSTimer *cpuMeterTimer;
@property (nonatomic, strong) NSTimer *ramMeterTimer;
@property (nonatomic, strong) NSTimer *diskMeterTimer;
@property (nonatomic) uint64_t lastCPUIdleTicks;
@property (nonatomic) uint64_t lastCPUTotalTicks;
@property (nonatomic) BOOL hasCPUReading;
@property (nonatomic) BOOL chatAutoScrollEnabled;

@end

@implementation CodexViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self raiseOpenFileLimitForLocalTools];
    self.view.backgroundColor = [self colorBackground];
    self.messages = [NSMutableArray array];
    self.files = @[];
    self.appLibrary = @[];
    self.projects = [NSMutableArray array];
    self.startedProjects = [NSMutableSet setWithArray:[[NSUserDefaults standardUserDefaults] objectForKey:CodexStartedProjectsKey] ?: @[]];
    self.runningPid = 0;
    self.activeAssistantIndex = NSNotFound;
    self.activeActivityIndex = NSNotFound;
    self.activeRunIsBuilder = NO;
    self.chatAutoScrollEnabled = YES;
    self.selectedModelName = @"gpt-5.5";
    self.selectedReasoningEffort = @"high";
    self.selectedReasoningLabel = @"High";
    [self buildInterface];
    [self prepareLocalRuntime];
    [self updateMode];
    [self registerForKeyboardNotifications];
    [self startSystemMeters];
}

- (void)raiseOpenFileLimitForLocalTools {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return;
    rlim_t target = 2048;
    if (limit.rlim_cur >= target) return;
    if (limit.rlim_max < target) target = limit.rlim_max;
    if (target <= limit.rlim_cur) return;
    limit.rlim_cur = target;
    setrlimit(RLIMIT_NOFILE, &limit);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateControlGeometry];
    [self updateComposerHeightAnimated:NO];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.workingTimer invalidate];
    [self.revealTimer invalidate];
    [self.cpuMeterTimer invalidate];
    [self.ramMeterTimer invalidate];
    [self.diskMeterTimer invalidate];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIColor *)colorBackground { return [UIColor colorWithRed:0.055 green:0.060 blue:0.070 alpha:1.0]; }
- (UIColor *)colorPanel { return [UIColor colorWithRed:0.090 green:0.096 blue:0.112 alpha:1.0]; }
- (UIColor *)colorPanelAlt { return [UIColor colorWithRed:0.150 green:0.158 blue:0.180 alpha:1.0]; }
- (UIColor *)colorBorder { return [UIColor colorWithWhite:0.28 alpha:1.0]; }
- (UIColor *)colorAccent { return [UIColor colorWithRed:0.35 green:0.82 blue:0.62 alpha:1.0]; }

- (void)startSystemMeters {
    [self updateCPUMeter];
    [self updateRAMMeter];
    [self updateDiskMeter];

    self.cpuMeterTimer = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(updateCPUMeter) userInfo:nil repeats:YES];
    self.ramMeterTimer = [NSTimer timerWithTimeInterval:10.0 target:self selector:@selector(updateRAMMeter) userInfo:nil repeats:YES];
    self.diskMeterTimer = [NSTimer timerWithTimeInterval:30.0 target:self selector:@selector(updateDiskMeter) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.cpuMeterTimer forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:self.ramMeterTimer forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:self.diskMeterTimer forMode:NSRunLoopCommonModes];
}

- (void)updateControlGeometry {
    NSArray<UIButton *> *roundButtons = @[self.menuButton ?: (UIButton *)[NSNull null],
                                          self.terminalButton ?: (UIButton *)[NSNull null],
                                          self.plusButton ?: (UIButton *)[NSNull null],
                                          self.runButton ?: (UIButton *)[NSNull null]];
    for (id item in roundButtons) {
        if (![item isKindOfClass:[UIButton class]]) continue;
        UIButton *button = (UIButton *)item;
        CGFloat side = MIN(CGRectGetWidth(button.bounds), CGRectGetHeight(button.bounds));
        if (side > 0) button.layer.cornerRadius = side / 2.0;
    }
    if (self.bottomMenuBar) self.bottomMenuBar.layer.cornerRadius = CGRectGetHeight(self.bottomMenuBar.bounds) / 2.0;
}

- (void)updateCPUMeter {
    processor_info_array_t cpuInfo = NULL;
    mach_msg_type_number_t numCPUInfo = 0;
    natural_t numCPUs = 0;
    kern_return_t result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo);
    if (result != KERN_SUCCESS || !cpuInfo || numCPUs == 0) return;

    uint64_t idle = 0;
    uint64_t total = 0;
    for (natural_t cpu = 0; cpu < numCPUs; cpu++) {
        processor_cpu_load_info_t load = (processor_cpu_load_info_t)&cpuInfo[cpu * CPU_STATE_MAX];
        uint64_t user = load->cpu_ticks[CPU_STATE_USER];
        uint64_t system = load->cpu_ticks[CPU_STATE_SYSTEM];
        uint64_t nice = load->cpu_ticks[CPU_STATE_NICE];
        uint64_t idleTicks = load->cpu_ticks[CPU_STATE_IDLE];
        idle += idleTicks;
        total += user + system + nice + idleTicks;
    }

    CGFloat percent = 0.0;
    if (self.hasCPUReading && total > self.lastCPUTotalTicks) {
        uint64_t totalDelta = total - self.lastCPUTotalTicks;
        uint64_t idleDelta = idle >= self.lastCPUIdleTicks ? idle - self.lastCPUIdleTicks : 0;
        percent = totalDelta > 0 ? (CGFloat)(totalDelta - idleDelta) / (CGFloat)totalDelta : 0.0;
    }
    self.lastCPUTotalTicks = total;
    self.lastCPUIdleTicks = idle;
    self.hasCPUReading = YES;

    vm_deallocate(mach_task_self(), (vm_address_t)cpuInfo, (vm_size_t)(numCPUInfo * sizeof(integer_t)));
    [self.cpuMeter setPercent:percent];
}

- (void)updateRAMMeter {
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);

    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t result = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmStats, &count);
    if (result != KERN_SUCCESS || pageSize == 0) return;

    uint64_t usedPages = (uint64_t)vmStats.active_count + (uint64_t)vmStats.inactive_count + (uint64_t)vmStats.wire_count;
    uint64_t freePages = (uint64_t)vmStats.free_count;
    uint64_t totalPages = usedPages + freePages;
    CGFloat percent = totalPages > 0 ? (CGFloat)usedPages / (CGFloat)totalPages : 0.0;
    [self.ramMeter setPercent:percent];
}

- (void)updateDiskMeter {
    struct statfs stats;
    NSString *path = self.documentsPath.length ? self.documentsPath : @"/private/var";
    if (statfs(path.fileSystemRepresentation, &stats) != 0 || stats.f_blocks == 0) return;
    uint64_t total = (uint64_t)stats.f_blocks;
    uint64_t free = (uint64_t)stats.f_bavail;
    CGFloat percent = total > 0 ? (CGFloat)(total - free) / (CGFloat)total : 0.0;
    [self.diskMeter setPercent:percent];
}

- (void)buildInterface {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    self.headerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.backgroundColor = [self colorBackground];
    [self.view addSubview:self.headerView];

    self.menuButton = [self iconButtonWithTitle:@"+"];
    [self.menuButton addTarget:self action:@selector(newProjectTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.menuButton];

    self.titleLabel = [self labelWithText:@"Codex" size:21 weight:UIFontWeightSemibold color:[UIColor whiteColor]];
    [self.headerView addSubview:self.titleLabel];

    self.statusLabel = [self labelWithText:@"Starting" size:12 weight:UIFontWeightSemibold color:[self colorAccent]];
    self.statusLabel.textAlignment = NSTextAlignmentRight;
    [self.headerView addSubview:self.statusLabel];

    self.terminalButton = [self iconButtonWithTitle:@"..."];
    [self.terminalButton addTarget:self action:@selector(terminalShortcutTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.terminalButton];

    self.metricsContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.metricsContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerView addSubview:self.metricsContainer];

    self.cpuMeter = [[CMMeterView alloc] initWithTitle:@"CPU" color:[UIColor colorWithRed:0.34 green:0.75 blue:1.00 alpha:1.0]];
    self.ramMeter = [[CMMeterView alloc] initWithTitle:@"RAM" color:[UIColor colorWithRed:0.35 green:0.82 blue:0.62 alpha:1.0]];
    self.diskMeter = [[CMMeterView alloc] initWithTitle:@"DSK" color:[UIColor colorWithRed:0.98 green:0.72 blue:0.34 alpha:1.0]];
    [self.metricsContainer addSubview:self.cpuMeter];
    [self.metricsContainer addSubview:self.ramMeter];
    [self.metricsContainer addSubview:self.diskMeter];

    self.chatTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.chatTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.chatTable.dataSource = self;
    self.chatTable.delegate = self;
    self.chatTable.backgroundColor = [self colorBackground];
    self.chatTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.chatTable.estimatedRowHeight = 112.0;
    self.chatTable.rowHeight = UITableViewAutomaticDimension;
    self.chatTable.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.chatTable registerClass:[CMChatCell class] forCellReuseIdentifier:@"ChatCell"];
    UITapGestureRecognizer *chatTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboardTapped:)];
    chatTap.cancelsTouchesInView = NO;
    [self.chatTable addGestureRecognizer:chatTap];
    [self.view addSubview:self.chatTable];

    self.filesTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.filesTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.filesTable.dataSource = self;
    self.filesTable.delegate = self;
    self.filesTable.backgroundColor = [self colorBackground];
    self.filesTable.separatorColor = [self colorBorder];
    self.filesTable.rowHeight = 46.0;
    [self.view addSubview:self.filesTable];

    self.terminalView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.terminalView.translatesAutoresizingMaskIntoConstraints = NO;
    self.terminalView.backgroundColor = [UIColor colorWithRed:0.030 green:0.035 blue:0.044 alpha:1.0];
    self.terminalView.textColor = [UIColor colorWithWhite:0.86 alpha:1.0];
    self.terminalView.tintColor = [self colorAccent];
    self.terminalView.font = [UIFont fontWithName:@"Menlo" size:11.3] ?: [UIFont systemFontOfSize:11.3];
    self.terminalView.editable = NO;
    self.terminalView.selectable = YES;
    self.terminalView.dataDetectorTypes = UIDataDetectorTypeLink;
    self.terminalView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.terminalView.layer.cornerRadius = 10.0;
    self.terminalView.layer.borderWidth = 1.0;
    self.terminalView.layer.borderColor = [self colorBorder].CGColor;
    [self.view addSubview:self.terminalView];

    self.bottomPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.bottomPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bottomPanel.backgroundColor = [self colorBackground];
    [self.view addSubview:self.bottomPanel];

    self.composerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.composerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.composerView.backgroundColor = [UIColor clearColor];
    [self.bottomPanel addSubview:self.composerView];

    self.plusButton = [self iconButtonWithTitle:@"+"];
    [self.plusButton addTarget:self action:@selector(menuTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.composerView addSubview:self.plusButton];

    self.composerTextView = [self composerTextViewWithPlaceholder:@"Message Codex"];
    self.composerTextView.delegate = self;
    [self.composerView addSubview:self.composerTextView];

    self.runButton = [self iconButtonWithTitle:@"↑"];
    self.runButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.64 blue:0.48 alpha:1.0];
    [self.runButton addTarget:self action:@selector(runTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.composerView addSubview:self.runButton];

    self.bottomMenuBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.bottomMenuBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.bottomMenuBar.backgroundColor = [UIColor colorWithRed:0.105 green:0.112 blue:0.130 alpha:1.0];
    self.bottomMenuBar.layer.borderWidth = 1.0;
    self.bottomMenuBar.layer.borderColor = [UIColor colorWithWhite:0.22 alpha:1.0].CGColor;
    [self.composerView addSubview:self.bottomMenuBar];

    self.accessButton = [self smallTextButtonWithTitle:@"GPT-5.5" color:[UIColor colorWithWhite:0.84 alpha:1.0]];
    [self.accessButton addTarget:self action:@selector(modelChooserTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomMenuBar addSubview:self.accessButton];

    self.modelButton = [self smallTextButtonWithTitle:@"Thinking High" color:[self colorAccent]];
    [self.modelButton addTarget:self action:@selector(thinkingChooserTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomMenuBar addSubview:self.modelButton];

    self.terminalToolbar = [[UIView alloc] initWithFrame:CGRectZero];
    self.terminalToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    self.terminalToolbar.backgroundColor = [UIColor clearColor];
    [self.bottomPanel addSubview:self.terminalToolbar];

    self.sessionsButton = [self toolbarButtonWithTitle:@"History"];
    [self.sessionsButton addTarget:self action:@selector(sessionsTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.terminalToolbar addSubview:self.sessionsButton];

    self.historyButton = [self toolbarButtonWithTitle:@"Files"];
    [self.historyButton addTarget:self action:@selector(pullHistoryTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.terminalToolbar addSubview:self.historyButton];

    self.terminalCopyButton = [self toolbarButtonWithTitle:@"Copy"];
    [self.terminalCopyButton addTarget:self action:@selector(copyTerminalTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.terminalToolbar addSubview:self.terminalCopyButton];

    self.stopButton = [self toolbarButtonWithTitle:@"Stop"];
    self.stopButton.backgroundColor = [UIColor colorWithRed:0.58 green:0.21 blue:0.20 alpha:1.0];
    [self.stopButton addTarget:self action:@selector(stopTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.terminalToolbar addSubview:self.stopButton];

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Chat", @"Apps", @"Files", @"Debug"]];
    self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeControl.selectedSegmentIndex = 0;
    [self.modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    self.modeControl.hidden = YES;
    [self.bottomPanel addSubview:self.modeControl];

    [self installConstraintsWithSafeArea:safe];
}

- (void)installConstraintsWithSafeArea:(UILayoutGuide *)safe {
    self.bottomPanelBottomConstraint = [self.bottomPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor];
    self.bottomPanelHeightConstraint = [self.bottomPanel.heightAnchor constraintEqualToConstant:CMComposerBasePanelHeight];
    self.composerViewHeightConstraint = [self.composerView.heightAnchor constraintEqualToConstant:CMComposerBaseViewHeight];
    self.composerTextViewHeightConstraint = [self.composerTextView.heightAnchor constraintEqualToConstant:CMComposerMinTextHeight];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.headerView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:74],

        [self.menuButton.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:12],
        [self.menuButton.topAnchor constraintEqualToAnchor:self.headerView.topAnchor constant:10],
        [self.menuButton.widthAnchor constraintEqualToConstant:34],
        [self.menuButton.heightAnchor constraintEqualToConstant:34],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.menuButton.trailingAnchor constant:8],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.menuButton.centerYAnchor],
        [self.titleLabel.widthAnchor constraintEqualToConstant:96],

        [self.terminalButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-12],
        [self.terminalButton.centerYAnchor constraintEqualToAnchor:self.menuButton.centerYAnchor],
        [self.terminalButton.widthAnchor constraintEqualToConstant:34],
        [self.terminalButton.heightAnchor constraintEqualToConstant:34],

        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.terminalButton.leadingAnchor constant:-8],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.menuButton.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.titleLabel.trailingAnchor constant:4],

        [self.metricsContainer.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:14],
        [self.metricsContainer.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-14],
        [self.metricsContainer.topAnchor constraintEqualToAnchor:self.menuButton.bottomAnchor constant:6],
        [self.metricsContainer.heightAnchor constraintEqualToConstant:18],

        [self.cpuMeter.leadingAnchor constraintEqualToAnchor:self.metricsContainer.leadingAnchor],
        [self.cpuMeter.topAnchor constraintEqualToAnchor:self.metricsContainer.topAnchor],
        [self.cpuMeter.bottomAnchor constraintEqualToAnchor:self.metricsContainer.bottomAnchor],
        [self.ramMeter.leadingAnchor constraintEqualToAnchor:self.cpuMeter.trailingAnchor constant:8],
        [self.ramMeter.topAnchor constraintEqualToAnchor:self.metricsContainer.topAnchor],
        [self.ramMeter.bottomAnchor constraintEqualToAnchor:self.metricsContainer.bottomAnchor],
        [self.ramMeter.widthAnchor constraintEqualToAnchor:self.cpuMeter.widthAnchor],
        [self.diskMeter.leadingAnchor constraintEqualToAnchor:self.ramMeter.trailingAnchor constant:8],
        [self.diskMeter.trailingAnchor constraintEqualToAnchor:self.metricsContainer.trailingAnchor],
        [self.diskMeter.topAnchor constraintEqualToAnchor:self.metricsContainer.topAnchor],
        [self.diskMeter.bottomAnchor constraintEqualToAnchor:self.metricsContainer.bottomAnchor],
        [self.diskMeter.widthAnchor constraintEqualToAnchor:self.cpuMeter.widthAnchor],

        [self.bottomPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.bottomPanel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        self.bottomPanelBottomConstraint,
        self.bottomPanelHeightConstraint,

        [self.chatTable.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.chatTable.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.chatTable.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.chatTable.bottomAnchor constraintEqualToAnchor:self.bottomPanel.topAnchor],

        [self.filesTable.leadingAnchor constraintEqualToAnchor:self.chatTable.leadingAnchor],
        [self.filesTable.trailingAnchor constraintEqualToAnchor:self.chatTable.trailingAnchor],
        [self.filesTable.topAnchor constraintEqualToAnchor:self.chatTable.topAnchor],
        [self.filesTable.bottomAnchor constraintEqualToAnchor:self.chatTable.bottomAnchor],

        [self.terminalView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
        [self.terminalView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
        [self.terminalView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:4],
        [self.terminalView.bottomAnchor constraintEqualToAnchor:self.bottomPanel.topAnchor constant:-4],

        [self.composerView.leadingAnchor constraintEqualToAnchor:self.bottomPanel.leadingAnchor constant:10],
        [self.composerView.trailingAnchor constraintEqualToAnchor:self.bottomPanel.trailingAnchor constant:-10],
        [self.composerView.topAnchor constraintEqualToAnchor:self.bottomPanel.topAnchor],
        self.composerViewHeightConstraint,

        [self.plusButton.leadingAnchor constraintEqualToAnchor:self.composerView.leadingAnchor],
        [self.plusButton.topAnchor constraintEqualToAnchor:self.composerView.topAnchor constant:7],
        [self.plusButton.widthAnchor constraintEqualToConstant:42],
        [self.plusButton.heightAnchor constraintEqualToConstant:42],

        [self.runButton.trailingAnchor constraintEqualToAnchor:self.composerView.trailingAnchor],
        [self.runButton.topAnchor constraintEqualToAnchor:self.plusButton.topAnchor],
        [self.runButton.widthAnchor constraintEqualToConstant:42],
        [self.runButton.heightAnchor constraintEqualToConstant:42],

        [self.composerTextView.leadingAnchor constraintEqualToAnchor:self.plusButton.trailingAnchor constant:7],
        [self.composerTextView.trailingAnchor constraintEqualToAnchor:self.runButton.leadingAnchor constant:-7],
        [self.composerTextView.topAnchor constraintEqualToAnchor:self.plusButton.topAnchor],
        self.composerTextViewHeightConstraint,

        [self.bottomMenuBar.leadingAnchor constraintEqualToAnchor:self.composerTextView.leadingAnchor],
        [self.bottomMenuBar.trailingAnchor constraintEqualToAnchor:self.composerTextView.trailingAnchor],
        [self.bottomMenuBar.topAnchor constraintEqualToAnchor:self.composerTextView.bottomAnchor constant:7],
        [self.bottomMenuBar.heightAnchor constraintEqualToConstant:22],

        [self.accessButton.leadingAnchor constraintEqualToAnchor:self.bottomMenuBar.leadingAnchor constant:4],
        [self.accessButton.topAnchor constraintEqualToAnchor:self.bottomMenuBar.topAnchor constant:3],
        [self.accessButton.bottomAnchor constraintEqualToAnchor:self.bottomMenuBar.bottomAnchor constant:-3],
        [self.accessButton.widthAnchor constraintEqualToConstant:76],

        [self.modelButton.trailingAnchor constraintEqualToAnchor:self.bottomMenuBar.trailingAnchor constant:-4],
        [self.modelButton.centerYAnchor constraintEqualToAnchor:self.accessButton.centerYAnchor],
        [self.modelButton.widthAnchor constraintEqualToConstant:124],
        [self.modelButton.heightAnchor constraintEqualToAnchor:self.accessButton.heightAnchor],

        [self.terminalToolbar.leadingAnchor constraintEqualToAnchor:self.bottomPanel.leadingAnchor constant:10],
        [self.terminalToolbar.trailingAnchor constraintEqualToAnchor:self.bottomPanel.trailingAnchor constant:-10],
        [self.terminalToolbar.topAnchor constraintEqualToAnchor:self.bottomPanel.topAnchor constant:10],
        [self.terminalToolbar.heightAnchor constraintEqualToConstant:48],

        [self.sessionsButton.leadingAnchor constraintEqualToAnchor:self.terminalToolbar.leadingAnchor],
        [self.sessionsButton.topAnchor constraintEqualToAnchor:self.terminalToolbar.topAnchor],
        [self.sessionsButton.widthAnchor constraintEqualToAnchor:self.historyButton.widthAnchor],
        [self.sessionsButton.heightAnchor constraintEqualToConstant:38],

        [self.historyButton.leadingAnchor constraintEqualToAnchor:self.sessionsButton.trailingAnchor constant:7],
        [self.historyButton.topAnchor constraintEqualToAnchor:self.sessionsButton.topAnchor],
        [self.historyButton.widthAnchor constraintEqualToAnchor:self.terminalCopyButton.widthAnchor],
        [self.historyButton.heightAnchor constraintEqualToAnchor:self.sessionsButton.heightAnchor],

        [self.terminalCopyButton.leadingAnchor constraintEqualToAnchor:self.historyButton.trailingAnchor constant:7],
        [self.terminalCopyButton.topAnchor constraintEqualToAnchor:self.sessionsButton.topAnchor],
        [self.terminalCopyButton.widthAnchor constraintEqualToAnchor:self.stopButton.widthAnchor],
        [self.terminalCopyButton.heightAnchor constraintEqualToAnchor:self.sessionsButton.heightAnchor],

        [self.stopButton.leadingAnchor constraintEqualToAnchor:self.terminalCopyButton.trailingAnchor constant:7],
        [self.stopButton.trailingAnchor constraintEqualToAnchor:self.terminalToolbar.trailingAnchor],
        [self.stopButton.topAnchor constraintEqualToAnchor:self.sessionsButton.topAnchor],
        [self.stopButton.heightAnchor constraintEqualToAnchor:self.sessionsButton.heightAnchor],

        [self.modeControl.leadingAnchor constraintEqualToAnchor:self.bottomPanel.leadingAnchor constant:10],
        [self.modeControl.trailingAnchor constraintEqualToAnchor:self.bottomPanel.trailingAnchor constant:-10],
        [self.modeControl.bottomAnchor constraintEqualToAnchor:self.bottomPanel.bottomAnchor constant:-4],
        [self.modeControl.heightAnchor constraintEqualToConstant:30]
    ]];
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.textColor = color;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.78;
    return label;
}

- (UIButton *)iconButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [self colorPanelAlt];
    button.tintColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    button.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 19.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:0.34 alpha:1.0].CGColor;
    button.layer.shadowColor = [UIColor blackColor].CGColor;
    button.layer.shadowOpacity = 0.22;
    button.layer.shadowRadius = 8.0;
    button.layer.shadowOffset = CGSizeMake(0, 3);
    [button setTitle:title forState:UIControlStateNormal];
    return button;
}

- (UIButton *)pillButtonWithTitle:(NSString *)title tint:(UIColor *)tint {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = tint;
    button.tintColor = [UIColor colorWithWhite:0.90 alpha:1.0];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.72;
    button.layer.cornerRadius = 15.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [self colorBorder].CGColor;
    [button setTitle:title forState:UIControlStateNormal];
    return button;
}

- (UIButton *)smallTextButtonWithTitle:(NSString *)title color:(UIColor *)color {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [UIColor colorWithRed:0.135 green:0.144 blue:0.166 alpha:1.0];
    button.tintColor = color;
    button.titleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    button.layer.cornerRadius = 8.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:0.24 alpha:1.0].CGColor;
    [button setTitle:title forState:UIControlStateNormal];
    return button;
}

- (UIButton *)toolbarButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [self colorPanelAlt];
    button.tintColor = [UIColor whiteColor];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.72;
    button.layer.cornerRadius = 9.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [self colorBorder].CGColor;
    [button setTitle:title forState:UIControlStateNormal];
    return button;
}

- (UITextView *)composerTextViewWithPlaceholder:(NSString *)placeholder {
    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.backgroundColor = [self colorPanelAlt];
    textView.textColor = [UIColor whiteColor];
    textView.tintColor = [self colorAccent];
    textView.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    textView.returnKeyType = UIReturnKeyDefault;
    textView.scrollEnabled = NO;
    textView.layer.cornerRadius = 21.0;
    textView.layer.borderWidth = 1.0;
    textView.layer.borderColor = [self colorBorder].CGColor;
    textView.textContainerInset = UIEdgeInsetsMake(11, 13, 9, 13);
    textView.textContainer.lineFragmentPadding = 0;

    self.composerPlaceholderLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.composerPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.composerPlaceholderLabel.text = placeholder;
    self.composerPlaceholderLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.composerPlaceholderLabel.font = textView.font;
    [textView addSubview:self.composerPlaceholderLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.composerPlaceholderLabel.leadingAnchor constraintEqualToAnchor:textView.leadingAnchor constant:15],
        [self.composerPlaceholderLabel.trailingAnchor constraintLessThanOrEqualToAnchor:textView.trailingAnchor constant:-12],
        [self.composerPlaceholderLabel.topAnchor constraintEqualToAnchor:textView.topAnchor constant:10]
    ]];
    return textView;
}

- (void)prepareLocalRuntime {
    NSFileManager *fm = [NSFileManager defaultManager];
    self.documentsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    self.projectsRootPath = [self.documentsPath stringByAppendingPathComponent:@"projects"];
    NSString *binPath = [self.documentsPath stringByAppendingPathComponent:@"bin"];

    NSError *error = nil;
    [fm createDirectoryAtPath:self.projectsRootPath withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        [self setStatus:@"Storage error" error:YES];
        [self appendLogLine:[NSString stringWithFormat:@"mkdir failed: %@", error.localizedDescription]];
        return;
    }
    error = nil;
    [fm createDirectoryAtPath:binPath withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        [self setStatus:@"Storage error" error:YES];
        [self appendLogLine:[NSString stringWithFormat:@"bin failed: %@", error.localizedDescription]];
        return;
    }

    NSString *bundledPath = [[NSBundle mainBundle] pathForResource:@"codex" ofType:nil];
    if (!bundledPath) bundledPath = [[NSBundle mainBundle] pathForResource:@"codex" ofType:nil inDirectory:@"Resources"];
    if (!bundledPath) {
        [self setStatus:@"Unavailable" error:YES];
        [self appendLogLine:@"engine missing"];
        return;
    }

    NSString *stagedCodex = [self stagedExecutableFromPath:bundledPath name:@"codex" destination:binPath label:@"codex"];
    self.codexPath = stagedCodex ?: bundledPath;
    [self chmodExecutableAtPath:self.codexPath];

    NSString *bundledProbe = [[NSBundle mainBundle] pathForResource:@"codex_probe" ofType:nil];
    if (!bundledProbe) bundledProbe = [[NSBundle mainBundle] pathForResource:@"codex_probe" ofType:nil inDirectory:@"Resources"];
    if (bundledProbe.length) {
        NSString *stagedProbe = [self stagedExecutableFromPath:bundledProbe name:@"codex_probe" destination:binPath label:@"codex_probe"];
        self.probePath = stagedProbe ?: bundledProbe;
        [self chmodExecutableAtPath:self.probePath];
    }

    NSString *appBuilderBinPath = @"/var/mobile/AppBuilder/bin";
    error = nil;
    if (![fm createDirectoryAtPath:appBuilderBinPath withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self appendLogLine:[NSString stringWithFormat:@"AppBuilder bin fallback: %@", error.localizedDescription]];
        appBuilderBinPath = binPath;
    }
    NSString *bundledBuilder = [[NSBundle mainBundle] pathForResource:@"appbuilder_build_project" ofType:@"sh"];
    if (!bundledBuilder) bundledBuilder = [[NSBundle mainBundle] pathForResource:@"appbuilder_build_project" ofType:@"sh" inDirectory:@"Resources"];
    if (bundledBuilder.length) {
        NSString *stagedBuilder = [self stagedExecutableFromPath:bundledBuilder name:@"appbuilder_build_project.sh" destination:appBuilderBinPath label:@"appbuilder"];
        self.appBuilderPath = stagedBuilder ?: bundledBuilder;
        [self chmodExecutableAtPath:self.appBuilderPath];
    } else {
        [self appendLogLine:@"appbuilder resource missing"];
    }

    NSString *bundledInstructions = [[NSBundle mainBundle] pathForResource:@"appbuilder_agent_instructions" ofType:@"md"];
    if (!bundledInstructions) bundledInstructions = [[NSBundle mainBundle] pathForResource:@"appbuilder_agent_instructions" ofType:@"md" inDirectory:@"Resources"];
    self.appBuilderInstructionsPath = bundledInstructions;

    [self loadProjects];
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:CodexCurrentProjectKey];
    if (!saved.length || ![self.projects containsObject:saved]) saved = self.projects.firstObject ?: @"Default";
    [self selectProject:saved];
    [self setStatus:@"Ready" error:NO];
    [self appendLogLine:[NSString stringWithFormat:@"== Diagnostics ==\nHOME %@\nConversation %@\nEngine %@\n", self.documentsPath, self.workspacePath, self.codexPath]];
}

- (void)chmodExecutableAtPath:(NSString *)path {
    chmod(path.fileSystemRepresentation, 0755);
}

- (NSString *)stagedExecutableFromPath:(NSString *)sourcePath name:(NSString *)name destination:(NSString *)destination label:(NSString *)label {
    if (!sourcePath.length || !destination.length || !name.length) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *targetPath = [destination stringByAppendingPathComponent:name];
    NSDictionary *sourceAttributes = [fm attributesOfItemAtPath:sourcePath error:nil];
    NSDictionary *targetAttributes = [fm attributesOfItemAtPath:targetPath error:nil];
    NSNumber *sourceSize = sourceAttributes[NSFileSize];
    NSNumber *targetSize = targetAttributes[NSFileSize];
    BOOL needsCopy = !targetSize || ![targetSize isEqualToNumber:sourceSize];

    if (needsCopy) {
        NSError *error = nil;
        if ([fm fileExistsAtPath:targetPath]) [fm removeItemAtPath:targetPath error:nil];
        if (![fm copyItemAtPath:sourcePath toPath:targetPath error:&error]) {
            [self appendLogLine:[NSString stringWithFormat:@"%@ stage failed: %@", label, error.localizedDescription]];
            return nil;
        }
        [self appendLogLine:[NSString stringWithFormat:@"%@ staged", label]];
    } else {
        [self appendLogLine:[NSString stringWithFormat:@"%@ ready", label]];
    }
    return targetPath;
}

- (void)loadProjects {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:self.projectsRootPath error:nil] ?: @[];
    [self.projects removeAllObjects];
    for (NSString *name in names) {
        NSString *path = [self.projectsRootPath stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) [self.projects addObject:name];
    }
    if (![self.projects containsObject:@"Default"]) {
        [fm createDirectoryAtPath:[self.projectsRootPath stringByAppendingPathComponent:@"Default"] withIntermediateDirectories:YES attributes:nil error:nil];
        [self.projects addObject:@"Default"];
    }
    [self.projects sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSString *)safeProjectNameFromText:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return nil;
    NSMutableString *safe = [NSMutableString stringWithCapacity:trimmed.length];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ "];
    for (NSUInteger i = 0; i < trimmed.length; i++) {
        unichar c = [trimmed characterAtIndex:i];
        [safe appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"-"];
    }
    return [safe stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)selectProject:(NSString *)name {
    if (!name.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    self.currentProjectName = name;
    self.workspacePath = [self.projectsRootPath stringByAppendingPathComponent:name];
    [fm createDirectoryAtPath:self.workspacePath withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:CodexCurrentProjectKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self ensureAgenticAppBuilderFilesForWorkspace];
    [self updateModelControls];
    [self loadMessagesForCurrentProject];
    [self reloadFiles];
}

- (void)ensureAgenticAppBuilderFilesForWorkspace {
    if (!self.workspacePath.length) return;
    NSString *instructions = nil;
    if (self.appBuilderInstructionsPath.length) {
        instructions = [NSString stringWithContentsOfFile:self.appBuilderInstructionsPath encoding:NSUTF8StringEncoding error:nil];
    }
    if (!instructions.length) {
        instructions = @"# iPhone App Builder Skill\n\nBuild Objective-C UIKit apps under Source/. Before implementation, use ImageGen 2 / imagegen to create app mockups and an app icon under Resources/, show those images in chat with absolute-path Markdown image links, then install with /var/mobile/AppBuilder/bin/appbuilder_build_project.sh .\n";
    }

    NSString *toolPath = self.appBuilderPath.length ? self.appBuilderPath : @"/var/mobile/AppBuilder/bin/appbuilder_build_project.sh";
    NSString *managedHeader = [NSString stringWithFormat:
        @"# AGENTS.md\n\nThis workspace is managed by CodexMobile on the iPhone.\n\nToolchain path: `%@`\n\n",
        toolPath];
    NSString *agentsText = [managedHeader stringByAppendingString:instructions];
    NSString *agentsPath = [self.workspacePath stringByAppendingPathComponent:@"AGENTS.md"];
    [agentsText writeToFile:agentsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *skillsRoot = [[self.documentsPath stringByAppendingPathComponent:@".codex"] stringByAppendingPathComponent:@"skills"];
    NSString *skillDir = [skillsRoot stringByAppendingPathComponent:@"iphone6-app-builder"];
    [[NSFileManager defaultManager] createDirectoryAtPath:skillDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *skillPath = [skillDir stringByAppendingPathComponent:@"SKILL.md"];
    [instructions writeToFile:skillPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSString *)chatPathForCurrentProject {
    return [self.workspacePath stringByAppendingPathComponent:@".codexmobile-chat.plist"];
}

- (void)loadMessagesForCurrentProject {
    NSArray *saved = [NSArray arrayWithContentsOfFile:[self chatPathForCurrentProject]];
    [self.messages removeAllObjects];
    BOOL normalized = NO;
    if ([saved isKindOfClass:[NSArray class]]) {
        for (id item in saved) {
            CMChatMessage *message = [CMChatMessage messageFromDictionary:item];
            if (!message) continue;
            if (![self normalizeLoadedActivityMessage:message]) {
                normalized = YES;
                continue;
            }
            if ([self isDuplicateLoadedFileChangeMessage:self.messages.lastObject current:message]) {
                normalized = YES;
                continue;
            }
            [self.messages addObject:message];
        }
    }
    [self.chatTable reloadData];
    [self forceScrollChatToBottom];
    if (normalized) [self saveMessagesForCurrentProject];
}

- (BOOL)isGenericLoadedActivityText:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return YES;
    if ([trimmed rangeOfString:@"Working for"].location != NSNotFound && [trimmed rangeOfString:@"Thinking"].location != NSNotFound) return YES;
    NSSet<NSString *> *generic = [NSSet setWithObjects:@"Preparing answer", @"Starting", @"Thinking", @"Thinking.", @"Thinking..", @"Thinking...", @"Finished", nil];
    return [generic containsObject:trimmed];
}

- (BOOL)normalizeLoadedActivityMessage:(CMChatMessage *)message {
    if (message.role != CMChatRoleActivity) return YES;
    NSMutableArray<CMChatBlock *> *blocks = [NSMutableArray array];
    for (CMChatBlock *block in message.blocks) {
        if (block.kind == CMChatBlockKindThinking) continue;
        if (block.kind == CMChatBlockKindCommandList) {
            if ([block.title isEqualToString:@"Running command"] || [block.title rangeOfString:@"commands"].location != NSNotFound) {
                block.title = @"Ran command";
            }
            if (block.items.count > 1) {
                NSString *last = block.items.lastObject;
                block.items = last.length ? @[last] : @[];
            }
        }
        if (block.kind == CMChatBlockKindFileChangeList && [block.title hasPrefix:@"Updating "]) {
            NSUInteger count = block.items.count;
            block.title = [NSString stringWithFormat:@"%lu %@ changed", (unsigned long)count, count == 1 ? @"file" : @"files"];
        }
        if (block.kind == CMChatBlockKindText) {
            if (block.text.length && [self isGenericLoadedActivityText:block.text]) continue;
            NSMutableArray<NSString *> *items = [NSMutableArray array];
            for (NSString *item in block.items) {
                if (![self isGenericLoadedActivityText:item]) [items addObject:item];
            }
            if (block.items.count && !items.count && !block.text.length) continue;
            block.items = items;
        }
        [blocks addObject:block];
    }
    message.blocks = blocks;
    return message.blocks.count > 0;
}

- (BOOL)isDuplicateLoadedFileChangeMessage:(CMChatMessage *)previous current:(CMChatMessage *)current {
    if (previous.role != CMChatRoleActivity || current.role != CMChatRoleActivity) return NO;
    if (previous.blocks.count != 1 || current.blocks.count != 1) return NO;
    CMChatBlock *left = previous.blocks.firstObject;
    CMChatBlock *right = current.blocks.firstObject;
    if (left.kind != CMChatBlockKindFileChangeList || right.kind != CMChatBlockKindFileChangeList) return NO;
    return [left.title isEqualToString:right.title] && [left.items isEqualToArray:right.items];
}

- (void)saveMessagesForCurrentProject {
    NSMutableArray *serialized = [NSMutableArray arrayWithCapacity:self.messages.count];
    for (CMChatMessage *message in self.messages) [serialized addObject:[message dictionaryRepresentation]];
    [serialized writeToFile:[self chatPathForCurrentProject] atomically:YES];
}

- (void)rememberCurrentProjectHasSession {
    if (!self.currentProjectName.length) return;
    [self.startedProjects addObject:self.currentProjectName];
    [[NSUserDefaults standardUserDefaults] setObject:self.startedProjects.allObjects forKey:CodexStartedProjectsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)setStatus:(NSString *)status error:(BOOL)isError {
    self.statusLabel.text = status ?: @"";
    self.statusLabel.textColor = isError ? [UIColor colorWithRed:0.96 green:0.46 blue:0.40 alpha:1.0] : [self colorAccent];
}

- (void)modeChanged:(id)sender {
    [self updateMode];
}

- (void)updateMode {
    NSInteger mode = self.modeControl.selectedSegmentIndex;
    self.chatTable.hidden = mode != 0;
    self.filesTable.hidden = !(mode == 1 || mode == 2);
    self.terminalView.hidden = mode != 3;
    self.composerView.hidden = mode != 0;
    self.terminalToolbar.hidden = mode != 3;
    if (mode == 1) {
        [self reloadAppLibrary];
    } else if (mode == 2) {
        [self reloadFiles];
    } else {
        [self updateModelControls];
    }
}

- (NSString *)modelDisplayName {
    if ([self.selectedModelName isEqualToString:@"gpt-5.5"]) return @"GPT-5.5";
    if ([self.selectedModelName isEqualToString:@"gpt-5.4"]) return @"GPT-5.4";
    if ([self.selectedModelName isEqualToString:@"gpt-5.2"]) return @"GPT-5.2";
    return self.selectedModelName ?: @"GPT-5.5";
}

- (void)updateModelControls {
    NSString *model = [self modelDisplayName];
    NSString *thinking = self.selectedReasoningLabel ?: @"High";
    [self.accessButton setTitle:model forState:UIControlStateNormal];
    [self.modelButton setTitle:[NSString stringWithFormat:@"Thinking %@", thinking] forState:UIControlStateNormal];
}

- (void)registerForKeyboardNotifications {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    CGRect keyboardFrame = [userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardInView = [self.view convertRect:keyboardFrame fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboardInView);
    if (notification.name == UIKeyboardWillHideNotification) overlap = 0;
    overlap = MAX(0, overlap);

    self.bottomPanelBottomConstraint.constant = -overlap;

    NSTimeInterval duration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState;
    NSNumber *curveValue = userInfo[UIKeyboardAnimationCurveUserInfoKey];
    if (curveValue) options |= (UIViewAnimationOptions)(curveValue.integerValue << 16);

    [UIView animateWithDuration:duration delay:0 options:options animations:^{
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        if (self.modeControl.selectedSegmentIndex == 0) [self scrollChatToBottom];
    }];
}

- (void)dismissKeyboardTapped:(UITapGestureRecognizer *)gesture {
    [self.view endEditing:YES];
}

- (void)presentDarkMenuWithTitle:(NSString *)title actions:(NSArray<CMMenuAction *> *)actions {
    if (!actions.count) return;
    [self dismissDarkMenu];
    [self.view endEditing:YES];
    self.activeMenuActions = actions;

    UIControl *overlay = [[UIControl alloc] initWithFrame:CGRectZero];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.56];
    [overlay addTarget:self action:@selector(dismissDarkMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:overlay];
    self.menuOverlayView = overlay;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithRed:0.105 green:0.112 blue:0.130 alpha:1.0];
    panel.layer.cornerRadius = 16.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithWhite:0.28 alpha:1.0].CGColor;
    panel.clipsToBounds = YES;
    [overlay addSubview:panel];

    UILabel *titleLabel = [self labelWithText:title ?: @"Menu" size:13 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.74 alpha:1.0]];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:titleLabel];

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = NO;
    [panel addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6.0;
    [scrollView addSubview:stack];

    for (NSUInteger i = 0; i < actions.count; i++) {
        CMMenuAction *action = actions[i];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.tag = (NSInteger)i;
        button.backgroundColor = action.destructive ? [UIColor colorWithRed:0.33 green:0.105 blue:0.105 alpha:1.0] : [UIColor colorWithRed:0.145 green:0.154 blue:0.176 alpha:1.0];
        button.tintColor = action.destructive ? [UIColor colorWithRed:1.0 green:0.48 blue:0.43 alpha:1.0] : [UIColor colorWithWhite:0.94 alpha:1.0];
        button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.72;
        button.layer.cornerRadius = 12.0;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = [UIColor colorWithWhite:0.24 alpha:1.0].CGColor;
        [button setTitle:action.title forState:UIControlStateNormal];
        [button addTarget:self action:@selector(darkMenuActionTapped:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
        [button.heightAnchor constraintEqualToConstant:44].active = YES;
    }

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    cancel.backgroundColor = [UIColor colorWithRed:0.125 green:0.132 blue:0.152 alpha:1.0];
    cancel.tintColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    cancel.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    cancel.layer.cornerRadius = 12.0;
    cancel.layer.borderWidth = 1.0;
    cancel.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1.0].CGColor;
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(dismissDarkMenu) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:cancel];

    CGFloat desiredHeight = 46.0 + actions.count * 50.0 + 62.0;
    CGFloat maxHeight = CGRectGetHeight(self.view.bounds) * 0.82;
    CGFloat panelHeight = MIN(MAX(220.0, desiredHeight), maxHeight > 0 ? maxHeight : 560.0);
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
        [panel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
        [panel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
        [panel.heightAnchor constraintEqualToConstant:panelHeight],

        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.topAnchor constant:12],
        [titleLabel.heightAnchor constraintEqualToConstant:24],

        [cancel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12],
        [cancel.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12],
        [cancel.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-12],
        [cancel.heightAnchor constraintEqualToConstant:44],

        [scrollView.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12],
        [scrollView.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12],
        [scrollView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
        [scrollView.bottomAnchor constraintEqualToAnchor:cancel.topAnchor constant:-10],

        [stack.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scrollView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.widthAnchor]
    ]];

    panel.transform = CGAffineTransformMakeTranslation(0, panelHeight);
    overlay.alpha = 0.0;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)darkMenuActionTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.activeMenuActions.count) return;
    CMMenuAction *action = self.activeMenuActions[(NSUInteger)index];
    void (^handler)(void) = action.handler;
    [self dismissDarkMenu];
    if (handler) handler();
}

- (void)dismissDarkMenu {
    if (!self.menuOverlayView) return;
    UIControl *overlay = self.menuOverlayView;
    self.menuOverlayView = nil;
    self.activeMenuActions = nil;
    [UIView animateWithDuration:0.14 animations:^{
        overlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)terminalShortcutTapped:(id)sender {
    [self presentDarkMenuWithTitle:@"More" actions:@[
        [CMMenuAction actionWithTitle:@"Diagnostics" destructive:NO handler:^{
        self.modeControl.selectedSegmentIndex = 3;
        [self updateMode];
        }],
        [CMMenuAction actionWithTitle:@"Files" destructive:NO handler:^{
        self.modeControl.selectedSegmentIndex = 2;
        [self updateMode];
        }],
        [CMMenuAction actionWithTitle:@"App Library" destructive:NO handler:^{
        self.modeControl.selectedSegmentIndex = 1;
        [self updateMode];
        }],
        [CMMenuAction actionWithTitle:@"Chat" destructive:NO handler:^{
        self.modeControl.selectedSegmentIndex = 0;
        [self updateMode];
        }]
    ]];
}

- (void)menuTapped:(id)sender {
    NSMutableArray<CMMenuAction *> *actions = [NSMutableArray arrayWithArray:@[
        [CMMenuAction actionWithTitle:@"New chat" destructive:NO handler:^{ [self newProjectTapped:sender]; }],
        [CMMenuAction actionWithTitle:@"Conversations" destructive:NO handler:^{ [self projectsTapped:sender]; }],
        [CMMenuAction actionWithTitle:@"App Library" destructive:NO handler:^{
        self.modeControl.selectedSegmentIndex = 1;
        [self updateMode];
        }],
        [CMMenuAction actionWithTitle:@"Model" destructive:NO handler:^{ [self modelChooserTapped:sender]; }],
        [CMMenuAction actionWithTitle:@"Thinking" destructive:NO handler:^{ [self thinkingChooserTapped:sender]; }],
        [CMMenuAction actionWithTitle:@"Sign in" destructive:NO handler:^{ [self loginTapped:sender]; }],
        [CMMenuAction actionWithTitle:@"Account" destructive:NO handler:^{ [self statusTapped:sender]; }],
        [CMMenuAction actionWithTitle:@"Diagnostics" destructive:NO handler:^{
        self.modeControl.selectedSegmentIndex = 3;
        [self updateMode];
        }],
        [CMMenuAction actionWithTitle:@"Conversation files" destructive:NO handler:^{
        self.modeControl.selectedSegmentIndex = 2;
        [self updateMode];
        }],
        [CMMenuAction actionWithTitle:@"Session history" destructive:NO handler:^{ [self pullHistoryTapped:sender]; }]
    ]];
    if (self.lastDeviceURL.length) [actions addObject:[CMMenuAction actionWithTitle:@"Open sign-in URL" destructive:NO handler:^{ [self openDeviceURLTapped:sender]; }]];
    if (self.lastDeviceCode.length) [actions addObject:[CMMenuAction actionWithTitle:@"Copy sign-in code" destructive:NO handler:^{ [self copyDeviceCodeTapped:sender]; }]];
    [actions addObject:[CMMenuAction actionWithTitle:@"Stop" destructive:YES handler:^{ [self stopTapped:sender]; }]];
    [self presentDarkMenuWithTitle:@"CodexMobile" actions:actions];
}

- (void)newProjectTapped:(id)sender {
    NSString *name = [self nextAutomaticChatName];
    [[NSFileManager defaultManager] createDirectoryAtPath:[self.projectsRootPath stringByAppendingPathComponent:name] withIntermediateDirectories:YES attributes:nil error:nil];
    [self.projects addObject:name];
    [self.projects sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self selectProject:name];
    self.modeControl.selectedSegmentIndex = 0;
    [self updateMode];
}

- (NSString *)nextAutomaticChatName {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *base = [NSString stringWithFormat:@"Chat %@", [formatter stringFromDate:[NSDate date]]];
    NSString *candidate = base;
    NSUInteger suffix = 2;
    while ([self.projects containsObject:candidate]) {
        candidate = [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)suffix++];
    }
    return candidate;
}

- (void)projectsTapped:(id)sender {
    NSMutableArray<CMMenuAction *> *actions = [NSMutableArray array];
    for (NSString *name in self.projects) {
        NSString *title = [name isEqualToString:self.currentProjectName] ? [name stringByAppendingString:@"  ✓"] : name;
        [actions addObject:[CMMenuAction actionWithTitle:title destructive:NO handler:^{
            [self selectProject:name];
            self.modeControl.selectedSegmentIndex = 0;
            [self updateMode];
        }]];
    }
    [actions addObject:[CMMenuAction actionWithTitle:@"New chat" destructive:NO handler:^{ [self newProjectTapped:sender]; }]];
    [self presentDarkMenuWithTitle:@"Conversations" actions:actions];
}

- (void)modelChooserTapped:(id)sender {
    NSArray<NSDictionary *> *models = @[
        @{@"title": @"GPT-5.5", @"value": @"gpt-5.5"},
        @{@"title": @"GPT-5.4", @"value": @"gpt-5.4"},
        @{@"title": @"GPT-5.2", @"value": @"gpt-5.2"}
    ];
    NSMutableArray<CMMenuAction *> *actions = [NSMutableArray array];
    for (NSDictionary *model in models) {
        NSString *title = model[@"title"];
        NSString *value = model[@"value"];
        if ([value isEqualToString:self.selectedModelName]) title = [title stringByAppendingString:@"  ✓"];
        [actions addObject:[CMMenuAction actionWithTitle:title destructive:NO handler:^{
            self.selectedModelName = value;
            [self updateModelControls];
        }]];
    }
    [self presentDarkMenuWithTitle:@"Model" actions:actions];
}

- (void)thinkingChooserTapped:(id)sender {
    NSArray<NSDictionary *> *levels = @[
        @{@"title": @"High", @"value": @"high"},
        @{@"title": @"Medium", @"value": @"medium"},
        @{@"title": @"Low", @"value": @"low"}
    ];
    NSMutableArray<CMMenuAction *> *actions = [NSMutableArray array];
    for (NSDictionary *level in levels) {
        NSString *title = level[@"title"];
        NSString *value = level[@"value"];
        if ([value isEqualToString:self.selectedReasoningEffort]) title = [title stringByAppendingString:@"  ✓"];
        [actions addObject:[CMMenuAction actionWithTitle:title destructive:NO handler:^{
            self.selectedReasoningEffort = value;
            self.selectedReasoningLabel = level[@"title"];
            [self updateModelControls];
        }]];
    }
    [self presentDarkMenuWithTitle:@"Thinking" actions:actions];
}

- (void)loginTapped:(id)sender {
    if (self.runningPid != 0) {
        [self appendLogLine:@"A request is already running."];
        return;
    }
    self.modeControl.selectedSegmentIndex = 3;
    [self updateMode];
    self.lastDeviceURL = nil;
    self.lastDeviceCode = nil;
    [self spawnCodexWithArguments:@[@"login", @"--device-auth"] workingDirectory:self.workspacePath chat:NO commandLabel:@"sign in"];
}

- (void)statusTapped:(id)sender {
    if (self.runningPid != 0) {
        [self appendLogLine:@"A request is already running."];
        return;
    }
    self.modeControl.selectedSegmentIndex = 3;
    [self updateMode];
    [self spawnCodexWithArguments:@[@"login", @"status"] workingDirectory:self.workspacePath chat:NO commandLabel:@"account status"];
}

- (void)helpTapped:(id)sender {
    if (self.runningPid != 0) {
        [self appendLogLine:@"A request is already running."];
        return;
    }
    self.modeControl.selectedSegmentIndex = 3;
    [self updateMode];
    [self spawnCodexWithArguments:@[@"exec", @"--help"] workingDirectory:self.workspacePath chat:NO commandLabel:@"help"];
}

- (void)sessionsTapped:(id)sender {
    [self pullHistoryTapped:sender];
}

- (void)pullHistoryTapped:(id)sender {
    self.modeControl.selectedSegmentIndex = 3;
    [self updateMode];
    NSString *codexHome = [self.documentsPath stringByAppendingPathComponent:@".codex"];
    [UIPasteboard generalPasteboard].string = codexHome;
    [self appendLogLine:[NSString stringWithFormat:@"\n== Session history ==\nPath copied: %@", codexHome]];

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:codexHome isDirectory:&isDirectory] || !isDirectory) {
        [self appendLogLine:@"No session history directory found yet."];
        return;
    }

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:codexHome];
    NSString *name = nil;
    NSUInteger shown = 0;
    while ((name = [enumerator nextObject]) && shown < 80) {
        NSString *path = [codexHome stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSNumber *size = attrs[NSFileSize] ?: @(0);
        [self appendLogLine:[NSString stringWithFormat:@"%@  %@ bytes", name, size]];
        shown++;
    }
    if (shown == 80) [self appendLogLine:@"... truncated at 80 entries"];
}

- (void)copyTerminalTapped:(id)sender {
    [UIPasteboard generalPasteboard].string = self.terminalView.text ?: @"";
    [self appendLogLine:@"Diagnostics copied."];
}

- (void)openDeviceURLTapped:(id)sender {
    if (!self.lastDeviceURL.length) {
        [self appendLogLine:@"No sign-in URL captured yet."];
        return;
    }
    NSURL *url = [NSURL URLWithString:self.lastDeviceURL];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)copyDeviceCodeTapped:(id)sender {
    if (!self.lastDeviceCode.length) {
        [self appendLogLine:@"No sign-in code captured yet."];
        return;
    }
    [UIPasteboard generalPasteboard].string = self.lastDeviceCode;
    [self appendLogLine:[NSString stringWithFormat:@"Copied code %@", self.lastDeviceCode]];
}

- (void)stopTapped:(id)sender {
    if (self.runningPid == 0) {
        [self appendLogLine:@"No request is running."];
        return;
    }
    kill(self.runningPid, SIGTERM);
    [self appendLogLine:@"Stop requested."];
}

- (void)runTapped:(id)sender {
    if (self.runningPid != 0) {
        [self appendLogLine:@"A request is already running."];
        return;
    }
    NSString *prompt = [self.composerTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!prompt.length) return;
    [self.composerTextView resignFirstResponder];
    [self sendChatPrompt:prompt];
    self.composerTextView.text = @"";
    [self updateComposerHeightAnimated:YES];
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView == self.composerTextView) {
        [self updateComposerHeightAnimated:YES];
    }
}

- (void)updateComposerHeightAnimated:(BOOL)animated {
    if (!self.composerTextView || !self.composerTextViewHeightConstraint) return;
    CGFloat width = CGRectGetWidth(self.composerTextView.bounds);
    if (width <= 0) return;

    CGSize fitting = [self.composerTextView sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    CGFloat textHeight = MIN(CMComposerMaxTextHeight, MAX(CMComposerMinTextHeight, ceil(fitting.height)));
    CGFloat extra = textHeight - CMComposerMinTextHeight;
    BOOL changed = fabs(self.composerTextViewHeightConstraint.constant - textHeight) > 0.5;

    self.composerTextViewHeightConstraint.constant = textHeight;
    self.composerViewHeightConstraint.constant = CMComposerBaseViewHeight + extra;
    self.bottomPanelHeightConstraint.constant = CMComposerBasePanelHeight + extra;
    self.composerTextView.scrollEnabled = fitting.height > CMComposerMaxTextHeight + 1.0;
    self.composerPlaceholderLabel.hidden = self.composerTextView.text.length > 0;
    if (!changed) return;

    void (^layoutBlock)(void) = ^{
        [self.view layoutIfNeeded];
    };
    if (animated && changed) {
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:layoutBlock completion:^(BOOL finished) {
            [self scrollChatToBottom];
        }];
    } else {
        layoutBlock();
    }
}

- (void)sendChatPrompt:(NSString *)prompt {
    self.modeControl.selectedSegmentIndex = 0;
    [self updateMode];

    [self.messages addObject:[CMChatMessage messageWithRole:CMChatRoleUser text:prompt]];
    [self.messages addObject:[CMChatMessage activityMessage]];
    self.activeActivityIndex = (NSInteger)self.messages.count - 1;
    self.activeAssistantIndex = NSNotFound;
    [self startActivityTranscript];
    [self.chatTable reloadData];
    [self forceScrollChatToBottom];
    [self saveMessagesForCurrentProject];

    NSString *agentPrompt = [self codexPromptForUserPrompt:prompt];

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:
        @"-c", [NSString stringWithFormat:@"model_reasoning_effort=%@", self.selectedReasoningEffort ?: @"high"],
        @"-c", @"model_reasoning_summary=detailed",
        @"exec",
        @"--skip-git-repo-check",
        @"--dangerously-bypass-approvals-and-sandbox",
        @"--model", self.selectedModelName ?: @"gpt-5.5",
        @"--json",
        @"--color", @"never",
        nil];

    BOOL resume = [self.startedProjects containsObject:self.currentProjectName];
    if (resume) {
        [args addObjectsFromArray:@[@"resume", @"--last", agentPrompt]];
    } else {
        [args addObject:agentPrompt];
    }

    NSString *label = [NSString stringWithFormat:@"chat %@", [self shortDisplayPrompt:prompt]];
    [self spawnCodexWithArguments:args workingDirectory:self.workspacePath chat:YES commandLabel:label];
}

- (NSString *)codexPromptForUserPrompt:(NSString *)prompt {
    if (![self shouldHandleAppBuildPrompt:prompt]) return prompt;
    NSString *toolPath = self.appBuilderPath.length ? self.appBuilderPath : @"/var/mobile/AppBuilder/bin/appbuilder_build_project.sh";
    return [NSString stringWithFormat:
        @"User request:\n%@\n\n"
         "This is an app-building request on the iPhone. Use the AGENTS.md / iphone6-app-builder skill in this workspace. "
         "Do the skill's visual preflight first: generate mock UI image(s) and an app icon with ImageGen 2 / imagegen, save them under Resources, and show them in chat with absolute-path Markdown image links. "
         "Then design and implement a real Objective-C UIKit app from the request, write local source files, create appbuilder.conf, "
         "build and install it by running `%@ .`, inspect the build log if needed, fix errors, and continue until the app is installed and launched. "
         "Do not use a title-only template; make the app functional according to the request.",
        prompt, toolPath];
}

- (BOOL)shouldHandleAppBuildPrompt:(NSString *)prompt {
    NSString *lower = prompt.lowercaseString ?: @"";
    if ([lower rangeOfString:@"app"].location == NSNotFound) return NO;
    NSArray<NSString *> *verbs = @[@"build", @"install", @"create", @"make"];
    for (NSString *verb in verbs) {
        if ([lower rangeOfString:verb].location != NSNotFound) return YES;
    }
    return NO;
}

- (void)sendAppBuildPrompt:(NSString *)prompt {
    self.modeControl.selectedSegmentIndex = 0;
    [self updateMode];

    NSString *appName = [self appBuilderNameFromPrompt:prompt];
    NSString *bundleID = [NSString stringWithFormat:@"com.angad.generated.%@", [self bundleSlugForAppName:appName]];
    NSString *logPath = [NSString stringWithFormat:@"/var/mobile/AppBuilder/Projects/%@/build.log", appName];

    [self.messages addObject:[CMChatMessage messageWithRole:CMChatRoleUser text:prompt]];
    [self.messages addObject:[CMChatMessage activityMessage]];
    self.activeActivityIndex = (NSInteger)self.messages.count - 1;
    self.activeAssistantIndex = NSNotFound;
    self.activeRunIsChat = YES;
    self.activeRunIsBuilder = YES;
    self.activeBuilderAppName = appName;
    self.activeBuilderBundleID = bundleID;
    self.activeBuilderLogPath = logPath;
    [self startActivityTranscript];
    [self appendActivityLine:[NSString stringWithFormat:@"Building %@", appName]];
    [self.chatTable reloadData];
    [self forceScrollChatToBottom];
    [self saveMessagesForCurrentProject];

    if (!self.appBuilderPath.length) {
        [self finishAppBuilderRunWithSuccess:NO statusMessage:@"appbuilder script is missing"];
        self.activeRunIsChat = NO;
        self.activeRunIsBuilder = NO;
        self.activeAssistantIndex = NSNotFound;
        return;
    }

    NSString *root = @"/var/mobile/AppBuilder";
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *label = [NSString stringWithFormat:@"build %@ %@", appName, bundleID];
    [self spawnExecutableAtPath:@"/bin/sh"
                    displayName:@"appbuilder"
                      arguments:@[self.appBuilderPath, appName, bundleID]
               workingDirectory:root
                  homeDirectory:@"/var/mobile"
                    commandLabel:label];
    if (self.runningPid != 0) [self setStatus:@"Building" error:NO];
}

- (NSString *)firstCaptureInText:(NSString *)text pattern:(NSString *)pattern {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text ?: @"" options:0 range:NSMakeRange(0, text.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    NSRange range = [match rangeAtIndex:1];
    if (range.location == NSNotFound || range.length == 0) return nil;
    return [text substringWithRange:range];
}

- (NSString *)appBuilderNameFromPrompt:(NSString *)prompt {
    NSString *candidate = [self firstCaptureInText:prompt pattern:@"(?:called|named)\\s+([A-Za-z][A-Za-z0-9 _-]{0,30})"];
    if (!candidate.length) {
        NSArray<NSString *> *words = [[prompt.lowercaseString componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *word, NSDictionary *bindings) {
            return word.length > 0;
        }]];
        NSUInteger appIndex = NSNotFound;
        for (NSUInteger i = 0; i < words.count; i++) {
            if ([words[i] isEqualToString:@"app"]) {
                appIndex = i;
                break;
            }
        }
        if (appIndex != NSNotFound && appIndex > 0) {
            NSSet<NSString *> *skip = [NSSet setWithObjects:@"a", @"an", @"the", @"ios", @"iphone", @"simple", @"small", @"new", nil];
            for (NSInteger i = (NSInteger)appIndex - 1; i >= 0; i--) {
                NSString *word = words[(NSUInteger)i];
                if (![skip containsObject:word]) {
                    candidate = word;
                    break;
                }
            }
        }
    }
    if (!candidate.length) candidate = @"PhoneBuilt";

    NSArray<NSString *> *rawParts = [candidate componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    NSMutableString *name = [NSMutableString string];
    NSSet<NSString *> *stop = [NSSet setWithObjects:@"that", @"which", @"with", @"and", @"for", @"to", @"please", nil];
    for (NSString *part in rawParts) {
        if (!part.length) continue;
        NSString *lower = part.lowercaseString;
        if ([stop containsObject:lower]) break;
        NSString *first = [[part substringToIndex:1] uppercaseString];
        NSString *rest = part.length > 1 ? [[part substringFromIndex:1] lowercaseString] : @"";
        [name appendFormat:@"%@%@", first, rest];
        if (name.length >= 24) break;
    }
    if (!name.length) [name appendString:@"PhoneBuilt"];
    if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[name characterAtIndex:0]]) [name insertString:@"App" atIndex:0];
    if (name.length > 28) return [name substringToIndex:28];
    return name;
}

- (NSString *)bundleSlugForAppName:(NSString *)appName {
    NSMutableString *slug = [NSMutableString string];
    NSString *lower = appName.lowercaseString ?: @"phonebuilt";
    NSCharacterSet *allowed = [NSCharacterSet lowercaseLetterCharacterSet];
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([allowed characterIsMember:c] || (c >= '0' && c <= '9')) {
            [slug appendString:[NSString stringWithCharacters:&c length:1]];
        }
    }
    return slug.length ? slug : @"phonebuilt";
}

- (NSString *)shortDisplayPrompt:(NSString *)prompt {
    if (prompt.length <= 42) return prompt;
    return [[prompt substringToIndex:42] stringByAppendingString:@"..."];
}

- (void)startActivityTranscript {
    [self.workingTimer invalidate];
    [self.revealTimer invalidate];
    self.activeTurnStartDate = [NSDate date];
    self.jsonLineBuffer = [NSMutableString string];
    self.activeAssistantText = [NSMutableString string];
    self.pendingRevealText = nil;
    self.pendingRevealIndex = 0;
    self.activeAssistantHasFinalMessage = NO;
    self.activeActivityLines = [NSMutableArray arrayWithObject:@"Preparing answer"];
    self.activeCommandLines = [NSMutableArray array];
    self.activeChangedFiles = [NSMutableArray array];
    self.activeCommandFailed = NO;
    self.workingTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(refreshActiveActivityMessage) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.workingTimer forMode:NSRunLoopCommonModes];
    [self refreshActiveActivityMessage];
}

- (void)beginNewActivityCardWithLine:(NSString *)line {
    if (self.activeActivityIndex != NSNotFound && self.activeActivityIndex < (NSInteger)self.messages.count) {
        if ([self activeActivityCardIsRemovablePlaceholder]) {
            [self.messages removeObjectAtIndex:(NSUInteger)self.activeActivityIndex];
            if (self.activeAssistantIndex > self.activeActivityIndex) self.activeAssistantIndex -= 1;
            self.activeActivityIndex = NSNotFound;
        } else {
            [self updateActiveActivityMessageRunning:NO];
        }
    }
    [self.messages addObject:[CMChatMessage activityMessage]];
    self.activeActivityIndex = (NSInteger)self.messages.count - 1;
    self.activeActivityLines = [NSMutableArray array];
    if (line.length) [self.activeActivityLines addObject:line];
    self.activeCommandLines = [NSMutableArray array];
    self.activeChangedFiles = [NSMutableArray array];
    self.activeCommandFailed = NO;
    [self updateActiveActivityMessageRunning:self.runningPid != 0];
}

- (void)completeCurrentActivityCardAndClear {
    if (self.activeActivityIndex != NSNotFound && self.activeActivityIndex < (NSInteger)self.messages.count) {
        [self updateActiveActivityMessageRunning:NO];
    }
    self.activeActivityIndex = NSNotFound;
    self.activeActivityLines = [NSMutableArray array];
    self.activeCommandLines = [NSMutableArray array];
    self.activeChangedFiles = [NSMutableArray array];
    self.activeCommandFailed = NO;
}

- (BOOL)activeActivityCardIsRemovablePlaceholder {
    if (self.activeActivityIndex == NSNotFound || self.activeActivityIndex >= (NSInteger)self.messages.count) return NO;
    if (self.activeCommandLines.count || self.activeChangedFiles.count) return NO;
    NSSet<NSString *> *generic = [NSSet setWithObjects:@"Preparing answer", @"Starting", @"Thinking", @"Finished", nil];
    for (NSString *line in self.activeActivityLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length && ![generic containsObject:trimmed]) return NO;
    }
    return YES;
}

- (void)removeActiveActivityCardIfIdle {
    if (![self activeActivityCardIsRemovablePlaceholder]) return;
    [self.messages removeObjectAtIndex:(NSUInteger)self.activeActivityIndex];
    if (self.activeAssistantIndex > self.activeActivityIndex) self.activeAssistantIndex -= 1;
    self.activeActivityIndex = NSNotFound;
    [self.chatTable reloadData];
    [self scrollChatToBottom];
    [self saveMessagesForCurrentProject];
}

- (void)finishActivityTranscriptWithLine:(NSString *)line {
    if (!self.activeAssistantHasFinalMessage && line.length) [self appendActivityLine:line];
    [self.workingTimer invalidate];
    self.workingTimer = nil;
    self.activeTurnStartDate = nil;
    self.jsonLineBuffer = nil;
    if (self.activeAssistantHasFinalMessage) {
        [self removeActiveActivityCardIfIdle];
    } else {
        [self updateActiveActivityMessageRunning:NO];
    }
    if (self.revealTimer) {
        return;
    }
    if (self.activeAssistantText.length) {
        [self replaceActiveAssistantText:self.activeAssistantText];
    }
    self.activeAssistantText = nil;
}

- (NSString *)workingDurationText {
    NSTimeInterval elapsed = self.activeTurnStartDate ? [[NSDate date] timeIntervalSinceDate:self.activeTurnStartDate] : 0;
    NSInteger seconds = MAX(0, (NSInteger)round(elapsed));
    NSInteger minutes = seconds / 60;
    seconds = seconds % 60;
    if (minutes > 0) return [NSString stringWithFormat:@"Working for %ldm %lds", (long)minutes, (long)seconds];
    return [NSString stringWithFormat:@"Working for %lds", (long)seconds];
}

- (void)refreshActiveActivityMessage {
    [self updateActiveActivityMessageRunning:YES];
}

- (void)updateActiveActivityMessageRunning:(BOOL)running {
    if (self.activeActivityIndex == NSNotFound || self.activeActivityIndex >= (NSInteger)self.messages.count) return;
    CMChatMessage *message = self.messages[(NSUInteger)self.activeActivityIndex];
    NSMutableArray<CMChatBlock *> *blocks = [NSMutableArray array];
    BOOL hasToolState = self.activeChangedFiles.count || self.activeCommandLines.count;
    if (running && !hasToolState) {
        NSString *thinking = [NSString stringWithFormat:@"_%@ - %@_", [self thinkingPulseText], [self workingDurationText]];
        [blocks addObject:[CMChatBlock blockWithKind:CMChatBlockKindThinking title:nil text:thinking items:nil]];
    }

    if (self.activeChangedFiles.count) {
        NSString *title = running ? [NSString stringWithFormat:@"Updating %lu %@", (unsigned long)self.activeChangedFiles.count, self.activeChangedFiles.count == 1 ? @"file" : @"files"] : [NSString stringWithFormat:@"%lu %@ changed", (unsigned long)self.activeChangedFiles.count, self.activeChangedFiles.count == 1 ? @"file" : @"files"];
        NSUInteger maxFiles = MIN((NSUInteger)5, self.activeChangedFiles.count);
        NSMutableArray<NSString *> *files = [NSMutableArray arrayWithCapacity:maxFiles + 1];
        for (NSUInteger i = 0; i < maxFiles; i++) {
            [files addObject:self.activeChangedFiles[i]];
        }
        if (self.activeChangedFiles.count > maxFiles) [files addObject:[NSString stringWithFormat:@"+%lu more", (unsigned long)(self.activeChangedFiles.count - maxFiles)]];
        [blocks addObject:[CMChatBlock blockWithKind:CMChatBlockKindFileChangeList title:title text:nil items:files]];
    }

    if (self.activeCommandLines.count) {
        NSString *title = running ? @"Running command" : (self.activeCommandFailed ? @"Command failed" : @"Ran command");
        NSUInteger maxCommands = MIN((NSUInteger)1, self.activeCommandLines.count);
        NSMutableArray<NSString *> *commands = [NSMutableArray arrayWithCapacity:maxCommands];
        for (NSUInteger i = 0; i < maxCommands; i++) {
            [commands addObject:self.activeCommandLines[i]];
        }
        [blocks addObject:[CMChatBlock blockWithKind:CMChatBlockKindCommandList title:title text:nil items:commands]];
    }

    if (!self.activeChangedFiles.count && !self.activeCommandLines.count) {
        NSUInteger start = self.activeActivityLines.count > 3 ? self.activeActivityLines.count - 3 : 0;
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSUInteger i = start; i < self.activeActivityLines.count; i++) {
            NSString *line = self.activeActivityLines[i];
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length && ![self isGenericLoadedActivityText:trimmed]) [lines addObject:trimmed];
        }
        if (lines.count) [blocks addObject:[CMChatBlock blockWithKind:CMChatBlockKindText title:nil text:nil items:lines]];
    }

    if (!running && blocks.count == 0) [blocks addObject:[CMChatBlock blockWithKind:CMChatBlockKindText title:nil text:@"Finished" items:nil]];
    message.blocks = blocks;
    [self.chatTable reloadData];
    [self scrollChatToBottom];
    [self saveMessagesForCurrentProject];
}

- (NSString *)thinkingPulseText {
    NSTimeInterval elapsed = self.activeTurnStartDate ? [[NSDate date] timeIntervalSinceDate:self.activeTurnStartDate] : 0;
    NSInteger phase = ((NSInteger)floor(elapsed)) % 4;
    if (phase == 1) return @"Thinking.";
    if (phase == 2) return @"Thinking..";
    if (phase == 3) return @"Thinking...";
    return @"Thinking";
}

- (void)appendActivityLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return;
    if (self.activeActivityIndex == NSNotFound || self.activeActivityIndex >= (NSInteger)self.messages.count ||
        self.activeCommandLines.count || self.activeChangedFiles.count) {
        [self beginNewActivityCardWithLine:trimmed];
        return;
    }
    if (!self.activeActivityLines) self.activeActivityLines = [NSMutableArray array];
    if (![self.activeActivityLines.lastObject isEqualToString:trimmed]) {
        [self.activeActivityLines addObject:trimmed];
    }
    [self refreshActiveActivityMessage];
}

- (void)spawnCodexWithArguments:(NSArray<NSString *> *)arguments
               workingDirectory:(NSString *)workingDirectory
                            chat:(BOOL)chat
                    commandLabel:(NSString *)commandLabel {
    if (!self.codexPath.length) {
        [self appendLogLine:@"No engine binary path."];
        return;
    }
    self.activeRunIsChat = chat;
    [self spawnExecutableAtPath:self.codexPath
                    displayName:@"engine"
                      arguments:arguments
               workingDirectory:workingDirectory
                  homeDirectory:self.documentsPath
                    commandLabel:commandLabel ?: [arguments componentsJoinedByString:@" "]];
}

- (void)spawnExecutableAtPath:(NSString *)executablePath
                  displayName:(NSString *)displayName
                    arguments:(NSArray<NSString *> *)arguments
             workingDirectory:(NSString *)workingDirectory
                homeDirectory:(NSString *)homeDirectory
                  commandLabel:(NSString *)commandLabel {
    int outPipe[2] = {-1, -1};
    if (pipe(outPipe) != 0) {
        [self appendLogLine:[NSString stringWithFormat:@"pipe failed: %s", strerror(errno)]];
        return;
    }
    fcntl(outPipe[0], F_SETFL, O_NONBLOCK);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outPipe[0]);
    posix_spawn_file_actions_addclose(&actions, outPipe[1]);

    NSUInteger argc = arguments.count + 2;
    char **argv = calloc(argc, sizeof(char *));
    argv[0] = strdup(executablePath.fileSystemRepresentation);
    for (NSUInteger i = 0; i < arguments.count; i++) argv[i + 1] = strdup(arguments[i].UTF8String);
    argv[argc - 1] = NULL;

    NSString *homeEnv = [NSString stringWithFormat:@"HOME=%@", homeDirectory ?: NSHomeDirectory()];
    NSString *tmpEnv = [NSString stringWithFormat:@"TMPDIR=%@", NSTemporaryDirectory()];
    NSString *pathEnv = @"PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin:/usr/local/bin";
    NSString *termEnv = @"TERM=xterm-256color";
    NSString *columnsEnv = @"COLUMNS=80";
    char *envp[] = {
        (char *)homeEnv.UTF8String,
        (char *)tmpEnv.UTF8String,
        (char *)pathEnv.UTF8String,
        (char *)termEnv.UTF8String,
        (char *)columnsEnv.UTF8String,
        NULL
    };

    pid_t pid = 0;
    char oldCwd[PATH_MAX];
    BOOL canRestoreCwd = getcwd(oldCwd, sizeof(oldCwd)) != NULL;
    int chdirResult = chdir(workingDirectory.fileSystemRepresentation);
    if (chdirResult != 0) [self appendLogLine:[NSString stringWithFormat:@"chdir failed: %s", strerror(errno)]];
    int result = posix_spawn(&pid, executablePath.fileSystemRepresentation, &actions, NULL, argv, envp);
    if (canRestoreCwd) chdir(oldCwd);

    posix_spawn_file_actions_destroy(&actions);
    close(outPipe[1]);
    for (NSUInteger i = 0; i < argc - 1; i++) free(argv[i]);
    free(argv);

    if (result != 0) {
        close(outPipe[0]);
        [self appendExecutableDiagnosticsForPath:executablePath label:displayName];
        [self appendLogLine:[NSString stringWithFormat:@"%@\nposix_spawn failed: %s\npath: %@", displayName, strerror(result), executablePath]];
        [self setStatus:@"Failed" error:YES];
        if (self.activeRunIsChat) {
            [self ensureActiveAssistantMessage];
            [self appendToActiveAssistant:@"I couldn't start this request. Open Diagnostics for details.\n"];
        }
        self.activeRunIsChat = NO;
        self.activeRunIsBuilder = NO;
        self.activeBuilderAppName = nil;
        self.activeBuilderBundleID = nil;
        self.activeBuilderLogPath = nil;
        self.activeActivityIndex = NSNotFound;
        self.activeAssistantIndex = NSNotFound;
        return;
    }

    self.runningPid = pid;
    [self setStatus:@"Thinking" error:NO];
    [self appendLogLine:[NSString stringWithFormat:@"\n$ %@ %@", displayName, commandLabel ?: [arguments componentsJoinedByString:@" "]]];
    if (self.activeRunIsChat) [self refreshActiveActivityMessage];
    [self streamOutputFromFileDescriptor:outPipe[0] process:pid];
}

- (void)streamOutputFromFileDescriptor:(int)fd process:(pid_t)pid {
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
    __block BOOL closed = NO;
    dispatch_source_set_event_handler(source, ^{
        char buffer[4096];
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) {
            NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)count];
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!text.length) text = [NSString stringWithFormat:@"<%zd bytes>\n", count];
            dispatch_async(dispatch_get_main_queue(), ^{ [self appendProcessText:text]; });
        } else if (count == 0 || (count < 0 && errno != EAGAIN)) {
            if (!closed) {
                closed = YES;
                dispatch_source_cancel(source);
            }
        }
    });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_resume(source);

    dispatch_async(queue, ^{
        int status = 0;
        waitpid(pid, &status, 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.runningPid = 0;
            NSString *message = nil;
            BOOL success = NO;
            if (WIFEXITED(status)) {
                int code = WEXITSTATUS(status);
                success = code == 0;
                message = [NSString stringWithFormat:@"\n[exit %d]\n", code];
            } else if (WIFSIGNALED(status)) {
                message = [NSString stringWithFormat:@"\n[signal %d]\n", WTERMSIG(status)];
            } else {
                message = @"\n[process ended]\n";
            }
            [self appendLogText:message];
            if (self.activeRunIsBuilder) {
                [self finishAppBuilderRunWithSuccess:success statusMessage:[message stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            } else if (self.activeRunIsChat) {
                [self finishActivityTranscriptWithLine:success ? @"Finished" : [message stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            }
            if (self.activeRunIsChat && success && !self.activeRunIsBuilder) [self rememberCurrentProjectHasSession];
            self.activeRunIsChat = NO;
            self.activeRunIsBuilder = NO;
            self.activeBuilderAppName = nil;
            self.activeBuilderBundleID = nil;
            self.activeBuilderLogPath = nil;
            self.activeAssistantHasFinalMessage = NO;
            if (!self.revealTimer) {
                self.activeAssistantText = nil;
                self.activeAssistantIndex = NSNotFound;
            }
            self.activeActivityIndex = NSNotFound;
            [self reloadAppLibrary];
            [self reloadFiles];
            [self setStatus:@"Ready" error:NO];
        });
    });
}

- (void)appendProcessText:(NSString *)text {
    if (!text.length) return;
    NSString *cleanText = [self stringByStrippingANSI:text];
    [self captureDeviceAuthFromText:cleanText];
    [self appendLogText:cleanText];
    if (self.activeRunIsChat) {
        if (self.activeRunIsBuilder) {
            [self processAppBuilderText:cleanText];
        } else {
            [self processJSONLText:cleanText];
        }
    }
}

- (void)processAppBuilderText:(NSString *)text {
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!trimmed.length) continue;
        if ([trimmed hasPrefix:@"[builder]"]) {
            [self appendActivityLine:[trimmed stringByReplacingOccurrencesOfString:@"[builder] " withString:@""]];
        } else if ([trimmed rangeOfString:@"error" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [trimmed rangeOfString:@"warning" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [trimmed rangeOfString:@"failed" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [self appendActivityLine:trimmed];
        }
    }
}

- (void)finishAppBuilderRunWithSuccess:(BOOL)success statusMessage:(NSString *)statusMessage {
    [self.workingTimer invalidate];
    self.workingTimer = nil;
    self.activeTurnStartDate = nil;
    self.jsonLineBuffer = nil;
    self.activeAssistantText = nil;
    self.activeAssistantHasFinalMessage = YES;
    [self ensureActiveAssistantMessage];

    NSString *appName = self.activeBuilderAppName ?: @"App";
    NSString *bundleID = self.activeBuilderBundleID ?: @"";
    NSString *logPath = self.activeBuilderLogPath ?: @"";
    NSString *body = nil;
    if (success) {
        body = [NSString stringWithFormat:@"Built and installed `%@` on this iPhone.\n\nBundle: `%@`\nApp: `/Applications/%@.app`\nLog: `%@`", appName, bundleID, appName, logPath];
    } else {
        body = [NSString stringWithFormat:@"The on-device build for `%@` did not finish cleanly: `%@`.\n\nOpen Diagnostics for the compiler log.\nLog: `%@`", appName, statusMessage ?: @"failed", logPath];
    }
    [self replaceActiveAssistantText:body];
}

- (void)processJSONLText:(NSString *)text {
    if (!self.jsonLineBuffer) self.jsonLineBuffer = [NSMutableString string];
    [self.jsonLineBuffer appendString:text ?: @""];

    NSArray<NSString *> *parts = [self.jsonLineBuffer componentsSeparatedByString:@"\n"];
    [self.jsonLineBuffer setString:parts.lastObject ?: @""];
    if (parts.count <= 1) return;

    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        NSString *line = [parts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) continue;
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            if (![self isDiagnosticNoiseLine:line]) [self appendActivityLine:line];
            continue;
        }
        [self handleCodexJSONEvent:(NSDictionary *)parsed];
    }
}

- (BOOL)isDiagnosticNoiseLine:(NSString *)line {
    if (!line.length) return YES;
    NSRegularExpression *timestamp = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}T.*\\s+(WARN|ERROR)\\s+" options:0 error:nil];
    if ([timestamp firstMatchInString:line options:0 range:NSMakeRange(0, line.length)]) return YES;
    if ([line hasPrefix:@"Reading additional input from stdin"]) return YES;
    return NO;
}

- (NSString *)stringValueFromObject:(id)object fallback:(NSString *)fallback {
    if ([object isKindOfClass:[NSString class]]) return object;
    if ([object isKindOfClass:[NSNumber class]]) return [object stringValue];
    return fallback ?: @"";
}

- (void)handleCodexJSONEvent:(NSDictionary *)event {
    CMCodexEvent *codexEvent = [CMCodexEvent eventWithDictionary:event];
    if (!codexEvent) return;

    switch (codexEvent.kind) {
        case CMCodexEventKindStreamDelta:
            [self appendStreamingAssistantText:codexEvent.delta];
            break;
        case CMCodexEventKindThreadStarted:
            [self appendActivityLine:@"Starting"];
            break;
        case CMCodexEventKindTurnStarted:
            [self appendActivityLine:@"Thinking"];
            break;
        case CMCodexEventKindTurnCompleted:
            break;
        case CMCodexEventKindError:
            [self appendActivityLine:[NSString stringWithFormat:@"Error: %@", codexEvent.text ?: @"unknown"]];
            break;
        case CMCodexEventKindAgentMessage:
            if (codexEvent.delta.length) {
                [self appendStreamingAssistantText:codexEvent.delta];
                break;
            }
            if (codexEvent.text.length) {
            self.activeAssistantHasFinalMessage = YES;
            if (self.activeAssistantText.length) {
                    [self.activeAssistantText setString:codexEvent.text];
                    [self replaceActiveAssistantText:codexEvent.text];
            } else {
                    [self beginRevealingAssistantText:codexEvent.text];
            }
        }
            break;
        case CMCodexEventKindReasoning:
            if (codexEvent.text.length) [self appendActivityLine:codexEvent.text];
            break;
        case CMCodexEventKindCommandExecution:
            if (codexEvent.started) {
                NSString *command = codexEvent.command.length ? codexEvent.command : @"command";
                [self registerCommandLine:command];
            } else if (codexEvent.completed) {
                if ([codexEvent.status isEqualToString:@"failed"]) {
                    self.activeCommandFailed = YES;
                }
                [self completeCurrentActivityCardAndClear];
            }
            break;
        case CMCodexEventKindFileChange: {
            [self registerChangedFilesFromChanges:codexEvent.changes];
            if (codexEvent.completed) [self completeCurrentActivityCardAndClear];
            [self reloadFiles];
            break;
        }
        case CMCodexEventKindWebSearch:
            [self appendActivityLine:[NSString stringWithFormat:@"%@ %@", codexEvent.completed ? @"Searched" : @"Searching", [self compactInlineCode:codexEvent.query ?: @"web" maxLength:58]]];
            break;
        case CMCodexEventKindMCPToolCall:
            [self appendActivityLine:[NSString stringWithFormat:@"%@ %@/%@", codexEvent.completed ? @"Used" : @"Using", codexEvent.server ?: @"tool", codexEvent.tool ?: @""]];
            break;
        case CMCodexEventKindTodoList:
            if (codexEvent.todoItems.count) {
                NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:codexEvent.todoItems.count + 1];
            [lines addObject:@"Plan"];
                for (NSDictionary *todo in codexEvent.todoItems) {
                if (![todo isKindOfClass:[NSDictionary class]]) continue;
                NSString *text = [self stringValueFromObject:todo[@"text"] fallback:@""];
                BOOL done = [todo[@"completed"] boolValue];
                [lines addObject:[NSString stringWithFormat:@"%@ %@", done ? @"[x]" : @"[ ]", text]];
            }
            [self appendActivityLine:[lines componentsJoinedByString:@"\n"]];
        }
            break;
        case CMCodexEventKindUnknown:
        default:
            break;
    }
}

- (NSString *)compactInlineCode:(NSString *)text maxLength:(NSUInteger)maxLength {
    if (![text isKindOfClass:[NSString class]]) text = [self stringValueFromObject:text fallback:@""];
    NSString *single = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    if (single.length > maxLength) single = [[single substringToIndex:maxLength] stringByAppendingString:@"..."];
    return [NSString stringWithFormat:@"`%@`", single];
}

- (NSString *)commandDisplayFromObject:(id)object {
    if ([object isKindOfClass:[NSString class]]) return object;
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in (NSArray *)object) {
            NSString *part = [self stringValueFromObject:item fallback:@""];
            if (part.length) [parts addObject:part];
        }
        return [parts componentsJoinedByString:@" "];
    }
    return [self stringValueFromObject:object fallback:@""];
}

- (void)registerCommandLine:(NSString *)command {
    NSString *trimmed = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return;
    [self beginNewActivityCardWithLine:nil];
    self.activeCommandLines = [NSMutableArray arrayWithObject:trimmed];
    self.activeChangedFiles = [NSMutableArray array];
    self.activeActivityLines = [NSMutableArray array];
    self.activeCommandFailed = NO;
    [self refreshActiveActivityMessage];
}

- (void)registerChangedFilesFromChanges:(NSArray *)changes {
    if (![changes isKindOfClass:[NSArray class]]) return;
    BOOL canUpdateCurrentFileCard = self.activeActivityIndex != NSNotFound &&
        self.activeActivityIndex < (NSInteger)self.messages.count &&
        self.activeChangedFiles.count > 0 &&
        self.activeCommandLines.count == 0;
    if (!canUpdateCurrentFileCard) [self beginNewActivityCardWithLine:nil];
    self.activeChangedFiles = [NSMutableArray array];
    self.activeCommandLines = [NSMutableArray array];
    self.activeActivityLines = [NSMutableArray array];
    self.activeCommandFailed = NO;
    for (id change in changes) {
        NSString *path = [self pathFromFileChange:change];
        if (!path.length) continue;
        NSString *display = path;
        if ([display hasPrefix:@"/private/var/"]) display = [display substringFromIndex:@"/private".length];
        if ([display hasPrefix:self.workspacePath]) display = [display substringFromIndex:self.workspacePath.length];
        display = [display stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (!display.length) display = path.lastPathComponent ?: path;
        if (![self.activeChangedFiles containsObject:display]) [self.activeChangedFiles addObject:display];
    }
    [self refreshActiveActivityMessage];
}

- (NSString *)pathFromFileChange:(id)change {
    if ([change isKindOfClass:[NSString class]]) return change;
    if (![change isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = (NSDictionary *)change;
    NSArray<NSString *> *keys = @[@"path", @"file", @"name", @"target", @"relative_path"];
    for (NSString *key in keys) {
        NSString *value = [self stringValueFromObject:dict[key] fallback:@""];
        if (value.length) return value;
    }
    return nil;
}

- (void)appendStreamingAssistantText:(NSString *)delta {
    if (!delta.length) return;
    [self.revealTimer invalidate];
    self.revealTimer = nil;
    self.pendingRevealText = nil;
    [self ensureActiveAssistantMessage];
    if (!self.activeAssistantText) self.activeAssistantText = [NSMutableString string];
    [self.activeAssistantText appendString:delta];
    self.activeAssistantHasFinalMessage = YES;
    [self replaceActiveAssistantText:self.activeAssistantText];
}

- (void)beginRevealingAssistantText:(NSString *)text {
    [self.revealTimer invalidate];
    [self ensureActiveAssistantMessage];
    self.pendingRevealText = text ?: @"";
    self.pendingRevealIndex = 0;
    self.activeAssistantText = [NSMutableString string];
    self.activeAssistantHasFinalMessage = YES;
    self.revealTimer = [NSTimer timerWithTimeInterval:0.035 target:self selector:@selector(revealAssistantTextTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.revealTimer forMode:NSRunLoopCommonModes];
    [self revealAssistantTextTick:self.revealTimer];
}

- (void)revealAssistantTextTick:(NSTimer *)timer {
    if (!self.pendingRevealText.length) {
        [timer invalidate];
        self.revealTimer = nil;
        self.pendingRevealText = nil;
        return;
    }
    NSUInteger remaining = self.pendingRevealText.length - MIN(self.pendingRevealIndex, self.pendingRevealText.length);
    NSUInteger step = MIN((NSUInteger)MAX(3, remaining > 120 ? 8 : 5), remaining);
    if (step == 0) {
        [timer invalidate];
        self.revealTimer = nil;
        self.pendingRevealText = nil;
        if (self.activeAssistantText.length) [self replaceActiveAssistantText:self.activeAssistantText];
        self.activeAssistantText = nil;
        if (self.runningPid == 0) self.activeAssistantIndex = NSNotFound;
        return;
    }
    NSRange range = NSMakeRange(self.pendingRevealIndex, step);
    [self.activeAssistantText appendString:[self.pendingRevealText substringWithRange:range]];
    self.pendingRevealIndex += step;
    if (self.activeTurnStartDate) {
        [self replaceActiveAssistantText:self.activeAssistantText];
    } else {
        [self replaceActiveAssistantText:self.activeAssistantText];
    }
}

- (void)ensureActiveAssistantMessage {
    if (self.activeAssistantIndex != NSNotFound && self.activeAssistantIndex < (NSInteger)self.messages.count) return;
    CMChatMessage *message = [CMChatMessage messageWithRole:CMChatRoleAssistant text:@""];
    if (self.activeActivityIndex != NSNotFound && self.activeActivityIndex < (NSInteger)self.messages.count) {
        [self.messages insertObject:message atIndex:(NSUInteger)self.activeActivityIndex];
        self.activeAssistantIndex = self.activeActivityIndex;
        self.activeActivityIndex += 1;
    } else {
        [self.messages addObject:message];
        self.activeAssistantIndex = (NSInteger)self.messages.count - 1;
    }
    [self.chatTable reloadData];
    [self scrollChatToBottom];
    [self saveMessagesForCurrentProject];
}

- (NSString *)fileChangeSummaryFromChanges:(NSArray *)changes {
    if (![changes isKindOfClass:[NSArray class]] || !changes.count) return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id change in changes) {
        NSString *path = [self pathFromFileChange:change];
        if (!path.length) continue;
        NSString *display = path.lastPathComponent.length ? path.lastPathComponent : path;
        [names addObject:[self compactInlineCode:display maxLength:28]];
        if (names.count == 3) break;
    }
    if (!names.count) return nil;
    NSString *joined = [names componentsJoinedByString:@", "];
    NSUInteger extra = changes.count > names.count ? changes.count - names.count : 0;
    if (extra) joined = [joined stringByAppendingFormat:@" +%lu", (unsigned long)extra];
    return joined;
}

- (void)replaceActiveAssistantText:(NSString *)text {
    if (self.activeAssistantIndex == NSNotFound || self.activeAssistantIndex >= (NSInteger)self.messages.count) return;
    CMChatMessage *message = self.messages[(NSUInteger)self.activeAssistantIndex];
    [message setMarkdownText:text ?: @""];
    [self.chatTable reloadData];
    [self scrollChatToBottom];
    [self saveMessagesForCurrentProject];
}

- (void)replaceActiveActivityText:(NSString *)text {
    if (self.activeActivityIndex == NSNotFound || self.activeActivityIndex >= (NSInteger)self.messages.count) return;
    CMChatMessage *message = self.messages[(NSUInteger)self.activeActivityIndex];
    [message setSingleText:text ?: @""];
    [self.chatTable reloadData];
    [self scrollChatToBottom];
    [self saveMessagesForCurrentProject];
}

- (void)appendToActiveAssistant:(NSString *)text {
    if (!text.length || self.activeAssistantIndex == NSNotFound || self.activeAssistantIndex >= (NSInteger)self.messages.count) return;
    CMChatMessage *message = self.messages[(NSUInteger)self.activeAssistantIndex];
    NSString *old = [message displayText] ?: @"";
    [message setMarkdownText:[old stringByAppendingString:text]];
    [self.chatTable reloadData];
    [self scrollChatToBottom];
    [self saveMessagesForCurrentProject];
}

- (void)appendLogLine:(NSString *)line {
    [self appendLogText:[line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"]];
}

- (void)appendLogText:(NSString *)text {
    if (!text.length) return;
    self.terminalView.text = [self.terminalView.text stringByAppendingString:text];
    if (self.terminalView.text.length > 90000) {
        self.terminalView.text = [self.terminalView.text substringFromIndex:self.terminalView.text.length - 76000];
    }
    if (self.terminalView.text.length > 0) {
        NSRange range = NSMakeRange(self.terminalView.text.length - 1, 1);
        [self.terminalView scrollRangeToVisible:range];
    }
}

- (void)scrollChatToBottom {
    if (!self.chatAutoScrollEnabled) return;
    [self forceScrollChatToBottom];
}

- (void)forceScrollChatToBottom {
    if (self.messages.count == 0) return;
    self.chatAutoScrollEnabled = YES;
    NSIndexPath *last = [NSIndexPath indexPathForRow:(NSInteger)self.messages.count - 1 inSection:0];
    [self.chatTable scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionBottom animated:NO];
}

- (BOOL)isChatScrolledNearBottom {
    CGFloat contentHeight = self.chatTable.contentSize.height;
    CGFloat visibleHeight = CGRectGetHeight(self.chatTable.bounds) - self.chatTable.contentInset.top - self.chatTable.contentInset.bottom;
    if (contentHeight <= visibleHeight + 1.0) return YES;
    CGFloat visibleBottom = self.chatTable.contentOffset.y + CGRectGetHeight(self.chatTable.bounds) - self.chatTable.contentInset.bottom;
    return contentHeight - visibleBottom < 72.0;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.chatTable) {
        self.chatAutoScrollEnabled = [self isChatScrolledNearBottom];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView == self.chatTable) {
        self.chatAutoScrollEnabled = [self isChatScrolledNearBottom];
    }
}

- (NSString *)stringByStrippingANSI:(NSString *)text {
    if (!text.length) return @"";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\x1B\\[[0-9;?]*[A-Za-z]" options:0 error:nil];
    return [regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
}

- (void)captureDeviceAuthFromText:(NSString *)text {
    if (!text.length) return;
    NSRegularExpression *urlRegex = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s]+" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *urlMatches = [urlRegex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *match in urlMatches) {
        NSString *url = [text substringWithRange:match.range];
        url = [url stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@".,;:)"]];
        if ([url rangeOfString:@"device"].location != NSNotFound) self.lastDeviceURL = url;
    }

    NSRegularExpression *codeRegex = [NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*([A-Z0-9]{4}(?:-[A-Z0-9]{4}){0,3})\\s*$" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *codeMatches = [codeRegex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *match in codeMatches) {
        if (match.numberOfRanges > 1) {
            NSString *code = [text substringWithRange:[match rangeAtIndex:1]];
            if (code.length >= 6) self.lastDeviceCode = code;
        }
    }
}

- (void)appendExecutableDiagnosticsForPath:(NSString *)path label:(NSString *)label {
    struct stat info;
    errno = 0;
    int statResult = stat(path.fileSystemRepresentation, &info);
    int statErrno = errno;

    errno = 0;
    int accessResult = access(path.fileSystemRepresentation, X_OK);
    int accessErrno = errno;

    if (statResult == 0) {
        [self appendLogLine:[NSString stringWithFormat:@"%@ stat: mode=%04o uid=%d gid=%d size=%lld",
                             label, info.st_mode & 07777, info.st_uid, info.st_gid, (long long)info.st_size]];
    } else {
        [self appendLogLine:[NSString stringWithFormat:@"%@ stat failed: %s", label, strerror(statErrno)]];
    }
    [self appendLogLine:[NSString stringWithFormat:@"%@ access X_OK: %@%@",
                         label,
                         accessResult == 0 ? @"ok" : @"failed",
                         accessResult == 0 ? @"" : [NSString stringWithFormat:@" (%s)", strerror(accessErrno)]]];
}

- (void)reloadAppLibrary {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/AppBuilder/Projects";
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
    for (NSString *name in names) {
        NSString *projectPath = [root stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:projectPath isDirectory:&isDirectory] || !isDirectory) continue;

        NSString *appName = name;
        NSString *bundleID = [NSString stringWithFormat:@"com.angad.generated.%@", [self bundleSlugForAppName:name]];
        NSString *configPath = [projectPath stringByAppendingPathComponent:@"appbuilder.conf"];
        NSDictionary *config = [self shellConfigAtPath:configPath];
        if ([config[@"APP_NAME"] length]) appName = config[@"APP_NAME"];
        if ([config[@"BUNDLE_ID"] length]) bundleID = config[@"BUNDLE_ID"];

        NSString *installedPath = [NSString stringWithFormat:@"/Applications/%@.app", appName];
        NSString *infoPath = [installedPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if ([info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]]) bundleID = info[@"CFBundleIdentifier"];
        if ([info[@"CFBundleName"] isKindOfClass:[NSString class]]) appName = info[@"CFBundleName"];

        NSString *logPath = [projectPath stringByAppendingPathComponent:@"build.log"];
        NSDictionary *attrs = [fm attributesOfItemAtPath:logPath error:nil] ?: [fm attributesOfItemAtPath:projectPath error:nil] ?: @{};
        NSDate *date = attrs[NSFileModificationDate] ?: [NSDate dateWithTimeIntervalSince1970:0];
        BOOL installed = [fm fileExistsAtPath:installedPath];
        [apps addObject:@{
            @"name": appName ?: name,
            @"bundle": bundleID ?: @"",
            @"path": installedPath,
            @"project": projectPath,
            @"log": logPath,
            @"date": date,
            @"installed": @(installed)
        }];
    }
    self.appLibrary = [apps sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
    if (self.modeControl.selectedSegmentIndex == 1) [self.filesTable reloadData];
}

- (NSDictionary *)shellConfigAtPath:(NSString *)path {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!trimmed.length || [trimmed hasPrefix:@"#"]) continue;
        NSRange equals = [trimmed rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [[trimmed substringToIndex:equals.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[trimmed substringFromIndex:equals.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) || ([value hasPrefix:@"'"] && [value hasSuffix:@"'"])) {
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        }
        if (key.length && value.length) result[key] = value;
    }
    return result;
}

- (void)reloadFiles {
    if (!self.workspacePath.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:self.workspacePath];
    NSString *name = nil;
    while ((name = [enumerator nextObject]) && entries.count < 160) {
        if ([name hasPrefix:@".codex"]) continue;
        NSUInteger depth = [[name pathComponents] count];
        if (depth > 3) {
            [enumerator skipDescendants];
            continue;
        }
        NSString *path = [self.workspacePath stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        [fm fileExistsAtPath:path isDirectory:&isDirectory];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil] ?: @{};
        [entries addObject:@{
            @"name": name,
            @"isDirectory": @(isDirectory),
            @"size": attrs[NSFileSize] ?: @(0),
            @"date": attrs[NSFileModificationDate] ?: [NSDate dateWithTimeIntervalSince1970:0]
        }];
    }
    self.files = [entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL ad = [a[@"isDirectory"] boolValue];
        BOOL bd = [b[@"isDirectory"] boolValue];
        if (ad != bd) return ad ? NSOrderedDescending : NSOrderedAscending;
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
    [self.filesTable reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.chatTable) return MAX((NSInteger)self.messages.count, 1);
    if (self.modeControl.selectedSegmentIndex == 1) return MAX((NSInteger)self.appLibrary.count, 1);
    return self.files.count + 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.chatTable) {
        CMChatCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ChatCell" forIndexPath:indexPath];
        if (self.messages.count == 0) {
            CMChatMessage *empty = [CMChatMessage messageWithRole:CMChatRoleSystem text:@"What can I help you build, fix, or understand today?"];
            [cell configureWithMessage:empty empty:YES];
            return cell;
        }
        CMChatMessage *message = self.messages[(NSUInteger)indexPath.row];
        [cell configureWithMessage:message empty:NO];
        return cell;
    }

    static NSString *fileCellId = @"FileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:fileCellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:fileCellId];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [self colorBackground];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];

    if (self.modeControl.selectedSegmentIndex == 1) {
        if (!self.appLibrary.count) {
            cell.textLabel.text = @"No built apps yet";
            cell.detailTextLabel.text = @"Ask Codex to build an app and it will appear here.";
            cell.accessoryType = UITableViewCellAccessoryNone;
            return cell;
        }
        NSDictionary *app = self.appLibrary[(NSUInteger)indexPath.row];
        NSString *name = app[@"name"] ?: @"App";
        NSString *bundle = app[@"bundle"] ?: @"";
        BOOL installed = [app[@"installed"] boolValue];
        cell.textLabel.text = installed ? name : [name stringByAppendingString:@"  (not installed)"];
        cell.detailTextLabel.text = bundle.length ? bundle : app[@"path"];
        cell.accessoryType = installed ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        return cell;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.row == 0) {
        cell.textLabel.text = [NSString stringWithFormat:@"%@/", self.currentProjectName ?: @"Conversation"];
        cell.detailTextLabel.text = self.workspacePath ?: @"";
        return cell;
    }
    if (indexPath.row == 1) {
        cell.textLabel.text = @"Session history/";
        cell.detailTextLabel.text = [self.documentsPath stringByAppendingPathComponent:@".codex"];
        return cell;
    }

    NSDictionary *entry = self.files[(NSUInteger)indexPath.row - 2];
    BOOL isDirectory = [entry[@"isDirectory"] boolValue];
    NSString *name = entry[@"name"] ?: @"";
    NSNumber *size = entry[@"size"] ?: @(0);
    cell.textLabel.text = isDirectory ? [name stringByAppendingString:@"/"] : name;
    cell.detailTextLabel.text = isDirectory ? @"directory" : [NSString stringWithFormat:@"%@ bytes", size];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (tableView != self.filesTable || self.modeControl.selectedSegmentIndex != 1 || indexPath.row >= (NSInteger)self.appLibrary.count) return;
    NSDictionary *app = self.appLibrary[(NSUInteger)indexPath.row];
    NSString *bundle = app[@"bundle"] ?: @"";
    if (!bundle.length || ![app[@"installed"] boolValue]) return;
    [self appendLogLine:[NSString stringWithFormat:@"Opening %@", bundle]];
    [self spawnExecutableAtPath:@"/usr/bin/uiopen"
                    displayName:@"uiopen"
                      arguments:@[bundle]
               workingDirectory:@"/var/mobile"
                  homeDirectory:@"/var/mobile"
                    commandLabel:bundle];
}

@end
