#import <Foundation/Foundation.h>
#import "BKBook.h"

@interface BKLibraryStore : NSObject

+ (instancetype)sharedStore;
- (NSArray<BKBook *> *)books;
- (void)addBook:(BKBook *)book;
- (void)updateBook:(BKBook *)book;
- (void)deleteBook:(BKBook *)book;
- (BKBook *)bookWithIdentifier:(NSString *)identifier;
- (BOOL)containsISBN:(NSString *)isbn;

@end
