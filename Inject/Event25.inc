std::atomic<bool> autoEvent25{false};
void incomingEvent25(const char *input) noexcept {
    if(!autoEvent25.load()||!input)return;
    std::array<char,4097> text{};size_t n=0;
    for(;n<4096;++n){if(!read(reinterpret_cast<uint64_t>(input)+n,text[n]))return;if(!text[n])break;}
    if(!n||n==4096)return;
    NSString *message=[[NSString alloc] initWithBytes:text.data() length:n encoding:NSUTF8StringEncoding];
    if(!message)message=[[NSString alloc] initWithBytes:text.data() length:n encoding:NSWindowsCP1251StringEncoding];
    if(!message)return;
    const double received=NSProcessInfo.processInfo.systemUptime;
    dispatch_async(dispatch_get_main_queue(),^{
        if(autoEvent25.load())[[NSNotificationCenter defaultCenter] postNotificationName:@"ReactServerMessage25" object:nil userInfo:@{@"text":message,@"received":@(received)}];
    });
}
