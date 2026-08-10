// Sound Class CHOP が扱える組込みクラスIDを列挙する。
//
//   clang -fobjc-arc -framework Foundation -framework SoundAnalysis \
//         -o /tmp/sound_classes tools/sound_classes.m && /tmp/sound_classes
//
// **一覧は OS のバージョンに紐づく**（分類器は com.apple.SoundAnalysis.classifier.v1 だが、
// 中身が将来増減しうる）。README に貼ってあるのは macOS 26.6 時点の 303 件。
// 手元の環境で確かめたいときはこれを走らせる。
#import <Foundation/Foundation.h>
#import <SoundAnalysis/SoundAnalysis.h>
int main(void){ @autoreleasepool{
  NSError* e=nil;
  SNClassifySoundRequest* r=[[SNClassifySoundRequest alloc]
      initWithClassifierIdentifier:SNClassifierIdentifierVersion1 error:&e];
  if(!r){ printf("失敗: %s\n", e.localizedDescription.UTF8String); return 1; }
  NSArray<NSString*>* c=r.knownClassifications;
  printf("classifier=%s  クラス数=%lu\n\n", [SNClassifierIdentifierVersion1 UTF8String], (unsigned long)c.count);
  for (NSString* s in c) printf("%s\n", s.UTF8String);
  return 0; }}
