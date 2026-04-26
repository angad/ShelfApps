#import "BKBook.h"

static NSString *BKString(NSDictionary *dictionary, NSString *key, NSString *fallback) {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        return value;
    }
    return fallback;
}

@implementation BKBook

+ (instancetype)bookWithDictionary:(NSDictionary *)dictionary {
    BKBook *book = [[BKBook alloc] init];
    book.identifier = BKString(dictionary, @"identifier", [[NSUUID UUID] UUIDString]);
    book.title = BKString(dictionary, @"title", @"Untitled Book");
    book.author = BKString(dictionary, @"author", @"Unknown Author");
    book.isbn = BKString(dictionary, @"isbn", @"");
    book.year = BKString(dictionary, @"year", @"");
    book.status = BKString(dictionary, @"status", @"Owned");
    book.shelf = BKString(dictionary, @"shelf", @"Main shelf");
    book.conditionText = BKString(dictionary, @"conditionText", @"Good");
    book.note = BKString(dictionary, @"note", @"");
    book.borrowerName = BKString(dictionary, @"borrowerName", @"");
    book.coverImageURL = BKString(dictionary, @"coverImageURL", @"");
    book.goodreadsBookURL = BKString(dictionary, @"goodreadsBookURL", @"");
    book.goodreadsAverageRating = BKString(dictionary, @"goodreadsAverageRating", @"");
    book.goodreadsRatingsCount = BKString(dictionary, @"goodreadsRatingsCount", @"");
    book.resalePrice = BKString(dictionary, @"resalePrice", @"");
    book.resaleVendor = BKString(dictionary, @"resaleVendor", @"");
    book.resaleURL = BKString(dictionary, @"resaleURL", @"");
    book.resalePriceUpdatedAt = BKString(dictionary, @"resalePriceUpdatedAt", @"");
    book.resalePriceError = BKString(dictionary, @"resalePriceError", @"");
    book.coverColorHex = BKString(dictionary, @"coverColorHex", @"#5A2E1B");
    return book;
}

+ (BKBook *)bookWithTitle:(NSString *)title
                  author:(NSString *)author
                    isbn:(NSString *)isbn
                    year:(NSString *)year
                  status:(NSString *)status
                   shelf:(NSString *)shelf
               condition:(NSString *)condition
                    note:(NSString *)note
                   color:(NSString *)color {
    return [BKBook bookWithDictionary:@{
        @"identifier": [[NSUUID UUID] UUIDString],
        @"title": title,
        @"author": author,
        @"isbn": isbn,
        @"year": year,
        @"status": status,
        @"shelf": shelf,
        @"conditionText": condition,
        @"note": note,
        @"borrowerName": @"",
        @"coverImageURL": @"",
        @"goodreadsBookURL": @"",
        @"goodreadsAverageRating": @"",
        @"goodreadsRatingsCount": @"",
        @"resalePrice": @"",
        @"resaleVendor": @"",
        @"resaleURL": @"",
        @"resalePriceUpdatedAt": @"",
        @"resalePriceError": @"",
        @"coverColorHex": color
    }];
}

+ (NSArray<BKBook *> *)seedBooks {
    return @[
        [BKBook bookWithTitle:@"Harry Potter and the Sorcerer's Stone" author:@"J.K. Rowling" isbn:@"9780590353427" year:@"1998" status:@"Read" shelf:@"Fantasy shelf" condition:@"Well loved" note:@"The American first volume; an easy guest starting point." color:@"#7A2F23"],
        [BKBook bookWithTitle:@"Harry Potter and the Chamber of Secrets" author:@"J.K. Rowling" isbn:@"9780439064873" year:@"1999" status:@"Read" shelf:@"Fantasy shelf" condition:@"Good" note:@"Best paired with a quiet afternoon and tea." color:@"#285B4A"],
        [BKBook bookWithTitle:@"Harry Potter and the Prisoner of Azkaban" author:@"J.K. Rowling" isbn:@"9780439136365" year:@"1999" status:@"Read" shelf:@"Fantasy shelf" condition:@"Good" note:@"A favorite for visitors who like time-loop stories." color:@"#394E7A"],
        [BKBook bookWithTitle:@"Harry Potter and the Goblet of Fire" author:@"J.K. Rowling" isbn:@"9780439139601" year:@"2000" status:@"Read" shelf:@"Fantasy shelf" condition:@"Good" note:@"The series gets bigger and darker here." color:@"#7A5A22"],
        [BKBook bookWithTitle:@"Harry Potter and the Order of the Phoenix" author:@"J.K. Rowling" isbn:@"9780439358071" year:@"2003" status:@"Owned" shelf:@"Fantasy shelf" condition:@"Good" note:@"Longest volume; best for committed browsers." color:@"#4A405F"],
        [BKBook bookWithTitle:@"Harry Potter and the Half-Blood Prince" author:@"J.K. Rowling" isbn:@"9780439785969" year:@"2005" status:@"Owned" shelf:@"Fantasy shelf" condition:@"Very good" note:@"Mystery-heavy and fast to recommend." color:@"#5A3A2A"],
        [BKBook bookWithTitle:@"Harry Potter and the Deathly Hallows" author:@"J.K. Rowling" isbn:@"9780545010221" year:@"2007" status:@"Owned" shelf:@"Fantasy shelf" condition:@"Very good" note:@"The finale; keep near the rest of the set." color:@"#2F4B55"],
        [BKBook bookWithTitle:@"Project Hail Mary" author:@"Andy Weir" isbn:@"9780593135204" year:@"2021" status:@"Owned" shelf:@"Science fiction shelf" condition:@"Good" note:@"Value test copy; ThriftBooks currently returns a non-zero buyback quote for this ISBN." color:@"#365B66"]
    ];
}

+ (BKBook *)catalogBookForISBN:(NSString *)isbn {
    NSString *normalized = [[isbn componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
    for (BKBook *book in [BKBook seedBooks]) {
        if ([book.isbn isEqualToString:normalized]) {
            return [BKBook bookWithDictionary:[book dictionaryValue]];
        }
    }
    if (normalized.length > 0) {
        return [BKBook bookWithTitle:[NSString stringWithFormat:@"Scanned Book %@", normalized]
                              author:@"Unknown Author"
                                isbn:normalized
                                year:@""
                              status:@"Owned"
                               shelf:@"To place"
                           condition:@"Good"
                                note:@"Added from ISBN scanner. Edit this record once you confirm the title."
                               color:@"#5A2E1B"];
    }
    return nil;
}

- (NSDictionary *)dictionaryValue {
    return @{
        @"identifier": self.identifier ?: [[NSUUID UUID] UUIDString],
        @"title": self.title ?: @"Untitled Book",
        @"author": self.author ?: @"Unknown Author",
        @"isbn": self.isbn ?: @"",
        @"year": self.year ?: @"",
        @"status": self.status ?: @"Owned",
        @"shelf": self.shelf ?: @"Main shelf",
        @"conditionText": self.conditionText ?: @"Good",
        @"note": self.note ?: @"",
        @"borrowerName": self.borrowerName ?: @"",
        @"coverImageURL": self.coverImageURL ?: @"",
        @"goodreadsBookURL": self.goodreadsBookURL ?: @"",
        @"goodreadsAverageRating": self.goodreadsAverageRating ?: @"",
        @"goodreadsRatingsCount": self.goodreadsRatingsCount ?: @"",
        @"resalePrice": self.resalePrice ?: @"",
        @"resaleVendor": self.resaleVendor ?: @"",
        @"resaleURL": self.resaleURL ?: @"",
        @"resalePriceUpdatedAt": self.resalePriceUpdatedAt ?: @"",
        @"resalePriceError": self.resalePriceError ?: @"",
        @"coverColorHex": self.coverColorHex ?: @"#5A2E1B"
    };
}

- (UIColor *)coverColor {
    NSString *hex = [self.coverColorHex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0x5A2E1B;
    if (hex.length == 6) {
        [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
    }
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

@end
