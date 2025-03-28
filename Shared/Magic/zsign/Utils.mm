//
//  Utils.cpp
//  backdoor
//
//  Created by samara on 30.09.2024.
//

#include "Utils.hpp"
#import <Foundation/Foundation.h>

extern "C" {

const char* getDocumentsDirectory() {
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsDirectory = [paths firstObject];
	const char *documentsPath = [documentsDirectory UTF8String];
	return documentsPath;
}
}
