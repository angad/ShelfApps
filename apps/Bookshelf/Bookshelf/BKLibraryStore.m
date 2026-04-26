#import "BKLibraryStore.h"

static NSString * const BKLibraryDefaultsKey = @"Bookshelf.Library.v1";
static NSString * const BKLibraryValueSampleMigrationKey = @"Bookshelf.Library.ValueSampleAdded.v1";
static NSString * const BKLibraryValueSampleISBN = @"9780593135204";

@interface BKLibraryStore ()

@property (nonatomic, strong) NSMutableArray<BKBook *> *mutableBooks;

@end

@implementation BKLibraryStore

+ (instancetype)sharedStore {
    static BKLibraryStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[BKLibraryStore alloc] initPrivate];
    });
    return store;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSArray *saved = [[NSUserDefaults standardUserDefaults] objectForKey:BKLibraryDefaultsKey];
        self.mutableBooks = [NSMutableArray array];
        if ([saved isKindOfClass:[NSArray class]] && saved.count > 0) {
            for (NSDictionary *dictionary in saved) {
                if ([dictionary isKindOfClass:[NSDictionary class]]) {
                    [self.mutableBooks addObject:[BKBook bookWithDictionary:dictionary]];
                }
            }
        } else {
            [self.mutableBooks addObjectsFromArray:[BKBook seedBooks]];
            [self save];
        }
        [self addValueSampleBookIfNeeded];
    }
    return self;
}

- (NSArray<BKBook *> *)books {
    return [self.mutableBooks copy];
}

- (void)addBook:(BKBook *)book {
    if (!book) {
        return;
    }
    if (!book.identifier) {
        book.identifier = [[NSUUID UUID] UUIDString];
    }
    [self.mutableBooks insertObject:book atIndex:0];
    [self save];
}

- (void)updateBook:(BKBook *)book {
    if (!book.identifier) {
        return;
    }
    for (NSUInteger index = 0; index < self.mutableBooks.count; index++) {
        BKBook *candidate = self.mutableBooks[index];
        if ([candidate.identifier isEqualToString:book.identifier]) {
            self.mutableBooks[index] = book;
            [self save];
            return;
        }
    }
}

- (void)deleteBook:(BKBook *)book {
    if (!book.identifier) {
        return;
    }
    NSIndexSet *indexes = [self.mutableBooks indexesOfObjectsPassingTest:^BOOL(BKBook *candidate, NSUInteger idx, BOOL *stop) {
        return [candidate.identifier isEqualToString:book.identifier];
    }];
    if (indexes.count > 0) {
        [self.mutableBooks removeObjectsAtIndexes:indexes];
        [self save];
    }
}

- (BKBook *)bookWithIdentifier:(NSString *)identifier {
    for (BKBook *book in self.mutableBooks) {
        if ([book.identifier isEqualToString:identifier]) {
            return book;
        }
    }
    return nil;
}

- (BOOL)containsISBN:(NSString *)isbn {
    NSString *normalized = [[isbn componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (normalized.length == 0) {
        return NO;
    }
    for (BKBook *book in self.mutableBooks) {
        if ([book.isbn isEqualToString:normalized]) {
            return YES;
        }
    }
    return NO;
}

- (void)addValueSampleBookIfNeeded {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:BKLibraryValueSampleMigrationKey]) {
        return;
    }
    if (![self containsISBN:BKLibraryValueSampleISBN]) {
        BKBook *sample = [BKBook catalogBookForISBN:BKLibraryValueSampleISBN];
        if (sample) {
            [self.mutableBooks insertObject:sample atIndex:0];
            [self save];
        }
    }
    [defaults setBool:YES forKey:BKLibraryValueSampleMigrationKey];
    [defaults synchronize];
}

- (void)save {
    NSMutableArray *payload = [NSMutableArray arrayWithCapacity:self.mutableBooks.count];
    for (BKBook *book in self.mutableBooks) {
        [payload addObject:[book dictionaryValue]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:payload forKey:BKLibraryDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
