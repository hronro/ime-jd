//
//  JdIME-Bridging-Header.h
//
//  Exposes the private `setWindowLevel:` selector on IMKCandidates so the
//  candidate panel can be raised above high-level system UI — Spotlight,
//  the menu bar, and fullscreen apps — which otherwise paints over the
//  native panel (see UI/Candidates.swift).
//
//  IMKCandidates has responded to `setWindowLevel:` since macOS 10.14, but
//  Apple never declared it in the public InputMethodKit headers. This
//  category is a *forward declaration only* (no @implementation): it tells
//  Swift the selector exists; the framework supplies the implementation at
//  runtime. Our deployment target is macOS 12, so the method is always present.
//

#import <InputMethodKit/InputMethodKit.h>

@interface IMKCandidates (PrivateWindowLevel)
- (void)setWindowLevel:(NSInteger)level;
@end
