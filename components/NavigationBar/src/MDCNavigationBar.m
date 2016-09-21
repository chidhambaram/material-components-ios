/*
 Copyright 2016-present the Material Components for iOS authors. All Rights Reserved.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MDCNavigationBar.h"

#import "MaterialButtonBar.h"
#import "MaterialRTL.h"
#import "MaterialTypography.h"

#import <objc/runtime.h>

static inline CGFloat Ceil(CGFloat value) {
#if CGFLOAT_IS_DOUBLE
  return ceil(value);
#else
  return ceilf(value);
#endif
}

static inline CGFloat Floor(CGFloat value) {
#if CGFLOAT_IS_DOUBLE
  return floor(value);
#else
  return floorf(value);
#endif
}

static const CGFloat kNavigationBarDefaultHeight = 56;
static const CGFloat kNavigationBarPadDefaultHeight = 64;
static const UIEdgeInsets kTextInsets = {16, 16, 16, 16};
static const UIEdgeInsets kTextPadInsets = {20, 16, 20, 16};

// KVO contexts
static char *const kKVOContextMDCNavigationBar = "kKVOContextMDCNavigationBar";

static NSArray<NSString *> *MDCNavigationBarNavigationItemKVOPaths(void) {
  static dispatch_once_t onceToken;
  static NSArray<NSString *> *forwardingKeyPaths = nil;
  dispatch_once(&onceToken, ^{
    NSMutableArray<NSString *> *keyPaths = [NSMutableArray array];

    Protocol *headerProtocol = @protocol(MDCUINavigationItemObservables);
    unsigned int count = 0;
    objc_property_t *propertyList = protocol_copyPropertyList(headerProtocol, &count);
    if (propertyList) {
      for (unsigned int ix = 0; ix < count; ++ix) {
        [keyPaths addObject:[NSString stringWithFormat:@"%s", property_getName(propertyList[ix])]];
      }
      free(propertyList);
    }

    // Ensure that the plural bar button item key paths are listened to last, otherwise the
    // non-plural variant will cause the extra bar button items to be lost. Fun!
    NSArray<NSString *> *orderedKeyPaths = @[
      NSStringFromSelector(@selector(leftBarButtonItems)),
      NSStringFromSelector(@selector(rightBarButtonItems))
    ];
    [keyPaths removeObjectsInArray:orderedKeyPaths];
    [keyPaths addObjectsFromArray:orderedKeyPaths];

    forwardingKeyPaths = keyPaths;
  });
  return forwardingKeyPaths;
}

/**
 Indiana Jones style placeholder view for UINavigationBar. Ownership of UIBarButtonItem.customView
 and UINavigationItem.titleView are normally transferred to UINavigationController but we plan to
 steal them away. In order to avoid crashing during KVO updates, we steal the view away and
 replace it with a sandbag view.
 */
@interface MDCNavigationBarSandbagView : UIView
@end

@implementation MDCNavigationBarSandbagView
@end

@interface MDCNavigationBar (PrivateAPIs)

- (UILabel *)titleLabel;
- (MDCButtonBar *)leadingButtonBar;
- (MDCButtonBar *)trailingButtonBar;
- (UIControlContentVerticalAlignment)titleAlignment;

@end

@implementation MDCNavigationBar {
  id _observedNavigationItemLock;
  UINavigationItem *_observedNavigationItem;

  UILabel *_titleLabel;

  MDCButtonBar *_leadingButtonBar;
  MDCButtonBar *_trailingButtonBar;

  __weak UIViewController *_watchingViewController;
}

@synthesize leadingBarButtonItems = _leadingBarButtonItems;
@synthesize trailingBarButtonItems = _trailingBarButtonItems;
@synthesize hidesBackButton = _hidesBackButton;
@synthesize leadingItemsSupplementBackButton = _leadingItemsSupplementBackButton;
@synthesize titleView = _titleView;

- (void)dealloc {
  [self setObservedNavigationItem:nil];
}

- (void)commonMDCNavigationBarInit {
  _observedNavigationItemLock = [[NSObject alloc] init];

  _titleLabel = [[UILabel alloc] init];
  _titleLabel.font = [MDCTypography titleFont];
  _titleLabel.accessibilityTraits |= UIAccessibilityTraitHeader;
  _leadingButtonBar = [[MDCButtonBar alloc] init];
  _leadingButtonBar.layoutPosition = MDCButtonBarLayoutPositionLeading;
  _trailingButtonBar = [[MDCButtonBar alloc] init];
  _trailingButtonBar.layoutPosition = MDCButtonBarLayoutPositionTrailing;

  [self addSubview:_titleLabel];
  [self addSubview:_leadingButtonBar];
  [self addSubview:_trailingButtonBar];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super initWithCoder:aDecoder];
  if (self) {
    [self commonMDCNavigationBarInit];
  }
  return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    [self commonMDCNavigationBarInit];
  }
  return self;
}

#pragma mark Accessibility

- (NSArray<__kindof UIView *> *)accessibilityElements {
  return @[ _leadingButtonBar, self.titleView ?: _titleLabel, _trailingButtonBar ];
}

- (BOOL)isAccessibilityElement {
  return NO;
}

- (NSInteger)accessibilityElementCount {
  return self.accessibilityElements.count;
}

- (id)accessibilityElementAtIndex:(NSInteger)index {
  return self.accessibilityElements[index];
}

- (NSInteger)indexOfAccessibilityElement:(id)element {
  return [self.accessibilityElements indexOfObject:element];
}

#pragma mark UIView Overrides

- (void)layoutSubviews {
  [super layoutSubviews];

  CGSize leadingButtonBarSize = [_leadingButtonBar sizeThatFits:self.bounds.size];
  CGRect leadingButtonBarFrame =
      (CGRect){.origin = {0, self.bounds.origin.y}, .size = leadingButtonBarSize};
  _leadingButtonBar.frame = MDCRectFlippedForRTL(leadingButtonBarFrame, self.bounds.size.width,
                                                 self.mdc_effectiveUserInterfaceLayoutDirection);

  CGSize trailingButtonBarSize = [_trailingButtonBar sizeThatFits:self.bounds.size];
  CGRect trailingButtonBarFrame = (CGRect){
      .origin = {self.bounds.size.width - trailingButtonBarSize.width, self.bounds.origin.y},
      .size = trailingButtonBarSize};
  _trailingButtonBar.frame = MDCRectFlippedForRTL(trailingButtonBarFrame, self.bounds.size.width,
                                                  self.mdc_effectiveUserInterfaceLayoutDirection);

  const BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
  UIEdgeInsets textInsets = isPad ? kTextPadInsets : kTextInsets;

  CGRect textFrame = UIEdgeInsetsInsetRect(self.bounds, textInsets);
  textFrame.origin.x += _leadingButtonBar.frame.size.width;
  textFrame.size.width -= _leadingButtonBar.frame.size.width + _trailingButtonBar.frame.size.width;

  NSMutableParagraphStyle *paraStyle = [[NSMutableParagraphStyle alloc] init];
  paraStyle.lineBreakMode = _titleLabel.lineBreakMode;

  NSDictionary<NSString *, id> *attributes =
      @{NSFontAttributeName : _titleLabel.font, NSParagraphStyleAttributeName : paraStyle};

  CGSize titleSize = [_titleLabel.text boundingRectWithSize:textFrame.size
                                                    options:NSStringDrawingTruncatesLastVisibleLine
                                                 attributes:attributes
                                                    context:NULL]
                         .size;
  titleSize.width = Ceil(titleSize.width);
  titleSize.height = Ceil(titleSize.height);
  CGRect titleFrame = (CGRect){{textFrame.origin.x, 0}, titleSize};
  titleFrame = MDCRectFlippedForRTL(titleFrame, self.bounds.size.width,
                                    self.mdc_effectiveUserInterfaceLayoutDirection);
  UIControlContentVerticalAlignment titleAlignment = [self titleAlignment];
  _titleLabel.frame =
      [self mdc_frameAlignedVertically:titleFrame withinBounds:textFrame alignment:titleAlignment];
  self.titleView.frame = textFrame;

  // Button and title label alignment

  CGFloat titleTextRectHeight =
      [_titleLabel textRectForBounds:_titleLabel.bounds limitedToNumberOfLines:0].size.height;

  if (_titleLabel.hidden || titleTextRectHeight <= 0) {
    _leadingButtonBar.buttonTitleBaseline = 0;
    _trailingButtonBar.buttonTitleBaseline = 0;

  } else {
    // Assumes that the title is center-aligned vertically.
    CGFloat titleTextOriginY = (_titleLabel.frame.size.height - titleTextRectHeight) / 2;
    CGFloat titleTextHeight = titleTextOriginY + titleTextRectHeight + _titleLabel.font.descender;
    CGFloat titleBaseline = _titleLabel.frame.origin.y + titleTextHeight;
    _leadingButtonBar.buttonTitleBaseline = titleBaseline;
    _trailingButtonBar.buttonTitleBaseline = titleBaseline;
  }
}

- (CGSize)sizeThatFits:(CGSize)size {
  CGSize intrinsicContentSize = [self intrinsicContentSize];
  return CGSizeMake(size.width, intrinsicContentSize.height);
}

- (CGSize)intrinsicContentSize {
  const BOOL isPad = [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
  CGFloat height = (isPad ? kNavigationBarPadDefaultHeight : kNavigationBarDefaultHeight);
  return CGSizeMake(UIViewNoIntrinsicMetric, height);
}

#pragma mark Private

- (UILabel *)titleLabel {
  return _titleLabel;
}

- (MDCButtonBar *)leadingButtonBar {
  return _leadingButtonBar;
}

- (MDCButtonBar *)trailingButtonBar {
  return _trailingButtonBar;
}

- (UIControlContentVerticalAlignment)titleAlignment {
  return UIControlContentVerticalAlignmentTop;
}

#pragma mark KVO

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (context == kKVOContextMDCNavigationBar) {
    void (^mainThreadWork)(void) = ^{
      @synchronized(self->_observedNavigationItemLock) {
        if (object != _observedNavigationItem) {
          return;
        }

        [self setValue:[object valueForKey:keyPath] forKey:keyPath];
      }
    };

    // Ensure that UIKit modifications occur on the main thread.
    if ([NSThread isMainThread]) {
      mainThreadWork();
    } else {
      [[NSOperationQueue mainQueue] addOperationWithBlock:mainThreadWork];
    }

  } else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

#pragma mark Layout

- (CGRect)mdc_frameAlignedVertically:(CGRect)frame
                        withinBounds:(CGRect)bounds
                           alignment:(UIControlContentVerticalAlignment)alignment {
  switch (alignment) {
    case UIControlContentVerticalAlignmentBottom:
      return (CGRect){{frame.origin.x, CGRectGetMaxY(bounds) - frame.size.height}, frame.size};

    case UIControlContentVerticalAlignmentCenter: {
      CGFloat centeredY = Floor((bounds.size.height - frame.size.height) / 2) + bounds.origin.y;
      return (CGRect){{frame.origin.x, centeredY}, frame.size};
    }

    case UIControlContentVerticalAlignmentTop: {
      return (CGRect){{frame.origin.x, bounds.origin.y}, frame.size};
    }

    case UIControlContentVerticalAlignmentFill: {
      return bounds;
    }
  }
}

- (NSArray<UIBarButtonItem *> *)mdc_buttonItemsForLeadingBar {
  if (!self.leadingItemsSupplementBackButton && self.leadingBarButtonItems.count > 0) {
    return self.leadingBarButtonItems;
  }

  NSMutableArray<UIBarButtonItem *> *buttonItems = [NSMutableArray array];
  if (self.backItem && !self.hidesBackButton) {
    [buttonItems addObject:self.backItem];
  }
  [buttonItems addObjectsFromArray:self.leadingBarButtonItems];
  return buttonItems;
}

#pragma mark Colors

- (void)tintColorDidChange {
  [super tintColorDidChange];

  // Tint color should only modify interactive elements
  _leadingButtonBar.tintColor = self.tintColor;
  _trailingButtonBar.tintColor = self.tintColor;
}

#pragma mark Public

- (void)setTitle:(NSString *)title {
  // |self.titleTextAttributes| can only be set if |title| is set
  if (self.titleTextAttributes && title.length > 0) {
    _titleLabel.attributedText =
        [[NSAttributedString alloc] initWithString:title attributes:_titleTextAttributes];
  } else {
    _titleLabel.text = title;
  }
  [self setNeedsLayout];
}

- (NSString *)title {
  return _titleLabel.text;
}

- (void)setTitleView:(UIView *)titleView {
  if (self.titleView == titleView) {
    return;
  }
  // Ignore sandbag KVO events
  if ([_observedNavigationItem.titleView isKindOfClass:[MDCNavigationBarSandbagView class]]) {
    return;
  }
  [self.titleView removeFromSuperview];
  _titleView = titleView;
  [self addSubview:_titleView];

  _titleLabel.hidden = _titleView != nil;

  [self setNeedsLayout];

  // Swap in the sandbag (so that UINavigationController won't steal our view)
  if (titleView) {
    _observedNavigationItem.titleView = [[MDCNavigationBarSandbagView alloc] init];
  } else if (_observedNavigationItem.titleView) {
    _observedNavigationItem.titleView = nil;
  }
}

- (void)setTitleTextAttributes:(NSDictionary<NSString *, id> *)titleTextAttributes {
  // If title dictionary is equivalent, no need to make changes
  if ([_titleTextAttributes isEqualToDictionary:titleTextAttributes]) {
    return;
  }

  // Copy attributes dictionary
  _titleTextAttributes = [titleTextAttributes copy];
  if (_titleLabel) {
    // |_titleTextAttributes| can only be set if |self.title| is set
    if (_titleTextAttributes && self.title.length > 0) {
      // Set label text as newly created attributed string with attributes if non-nil
      _titleLabel.attributedText =
          [[NSAttributedString alloc] initWithString:self.title attributes:_titleTextAttributes];
    } else {
      // Otherwise set titleLabel text property
      _titleLabel.text = self.title;
    }
    [self setNeedsLayout];
  }
}

- (void)setLeadingBarButtonItems:(NSArray<UIBarButtonItem *> *)leadingBarButtonItems {
  _leadingBarButtonItems = [leadingBarButtonItems copy];
  _leadingButtonBar.items = [self mdc_buttonItemsForLeadingBar];
  [self setNeedsLayout];
}

- (void)setTrailingBarButtonItems:(NSArray<UIBarButtonItem *> *)trailingBarButtonItems {
  _trailingBarButtonItems = [trailingBarButtonItems copy];
  _trailingButtonBar.items = _trailingBarButtonItems;
  [self setNeedsLayout];
}

- (void)setLeadingBarButtonItem:(UIBarButtonItem *)leadingBarButtonItem {
  self.leadingBarButtonItems = leadingBarButtonItem ? @[ leadingBarButtonItem ] : nil;
}

- (UIBarButtonItem *)leadingBarButtonItem {
  return [self.leadingBarButtonItems firstObject];
}

- (void)setTrailingBarButtonItem:(UIBarButtonItem *)trailingBarButtonItem {
  self.trailingBarButtonItems = trailingBarButtonItem ? @[ trailingBarButtonItem ] : nil;
}

- (UIBarButtonItem *)trailingBarButtonItem {
  return [self.trailingBarButtonItems firstObject];
}

- (void)setBackBarButtonItem:(UIBarButtonItem *)backBarButtonItem {
  self.backItem = backBarButtonItem;
}

- (UIBarButtonItem *)backBarButtonItem {
  return self.backItem;
}

- (void)setBackItem:(UIBarButtonItem *)backItem {
  if (_backItem == backItem) {
    return;
  }
  _backItem = backItem;
  _leadingButtonBar.items = [self mdc_buttonItemsForLeadingBar];
  [self setNeedsLayout];
}

- (void)setHidesBackButton:(BOOL)hidesBackButton {
  if (_hidesBackButton == hidesBackButton) {
    return;
  }
  _hidesBackButton = hidesBackButton;
  _leadingButtonBar.items = [self mdc_buttonItemsForLeadingBar];
  [self setNeedsLayout];
}

- (void)setLeadingItemsSupplementBackButton:(BOOL)leadingItemsSupplementBackButton {
  if (_leadingItemsSupplementBackButton == leadingItemsSupplementBackButton) {
    return;
  }
  _leadingItemsSupplementBackButton = leadingItemsSupplementBackButton;
  _leadingButtonBar.items = [self mdc_buttonItemsForLeadingBar];
  [self setNeedsLayout];
}

- (void)setObservedNavigationItem:(UINavigationItem *)navigationItem {
  @synchronized(_observedNavigationItemLock) {
    if (navigationItem == _observedNavigationItem) {
      return;
    }

    NSArray<NSString *> *keyPaths = MDCNavigationBarNavigationItemKVOPaths();
    for (NSString *keyPath in keyPaths) {
      [_observedNavigationItem removeObserver:self
                                   forKeyPath:keyPath
                                      context:kKVOContextMDCNavigationBar];
    }

    _observedNavigationItem = navigationItem;

    NSKeyValueObservingOptions options =
        (NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial);
    for (NSString *keyPath in keyPaths) {
      [_observedNavigationItem addObserver:self
                                forKeyPath:keyPath
                                   options:options
                                   context:kKVOContextMDCNavigationBar];
    }
  }
}

- (void)observeNavigationItem:(UINavigationItem *)navigationItem {
  [self setObservedNavigationItem:navigationItem];
}

- (void)unobserveNavigationItem {
  [self setObservedNavigationItem:nil];
}

#pragma mark UINavigationItem interface matching

- (NSArray<UIBarButtonItem *> *)leftBarButtonItems {
  return self.leadingBarButtonItems;
}

- (void)setLeftBarButtonItems:(NSArray<UIBarButtonItem *> *)leftBarButtonItems {
  self.leadingBarButtonItems = leftBarButtonItems;
}

- (NSArray<UIBarButtonItem *> *)rightBarButtonItems {
  return self.trailingBarButtonItems;
}

- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)rightBarButtonItems {
  self.trailingBarButtonItems = rightBarButtonItems;
}

- (UIBarButtonItem *)leftBarButtonItem {
  return self.leadingBarButtonItem;
}

- (void)setLeftBarButtonItem:(UIBarButtonItem *)leftBarButtonItem {
  self.leadingBarButtonItem = leftBarButtonItem;
}

- (UIBarButtonItem *)rightBarButtonItem {
  return self.trailingBarButtonItem;
}

- (void)setRightBarButtonItem:(UIBarButtonItem *)rightBarButtonItem {
  self.trailingBarButtonItem = rightBarButtonItem;
}

- (BOOL)leftItemsSupplementBackButton {
  return self.leadingItemsSupplementBackButton;
}

- (void)setLeftItemsSupplementBackButton:(BOOL)leftItemsSupplementBackButton {
  self.leadingItemsSupplementBackButton = leftItemsSupplementBackButton;
}

@end