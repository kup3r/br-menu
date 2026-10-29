std::atomic<bool> autoEvent25{false};
bool readEventText25(const char *input,std::array<char,4097> &text,size_t &n) {
    const uint64_t address=reinterpret_cast<uint64_t>(input);
    while(n<4096) {
        const size_t block=std::min({size_t(128),size_t(4096-n),size_t(4096-((address+n)&4095))});
        if(!copy(address+n,text.data()+n,block))return false;
        const void *end=std::memchr(text.data()+n,0,block);
        if(end){n=size_t(static_cast<const char *>(end)-text.data());break;}
        n+=block;
    }
    return n>0&&n<4096;
}
void incomingEvent25(const char *input) noexcept {
    if(!autoEvent25.load()||!input)return;
    @autoreleasepool {
    std::array<char,4097> text{};size_t n=0;
    if(!readEventText25(input,text,n))return;
    NSString *message=[[NSString alloc] initWithBytes:text.data() length:n encoding:NSUTF8StringEncoding];
    if(!message)message=[[NSString alloc] initWithBytes:text.data() length:n encoding:NSWindowsCP1251StringEncoding];
    if(!message)return;
    const double received=NSProcessInfo.processInfo.systemUptime;
    dispatch_async(dispatch_get_main_queue(),^{
        if(autoEvent25.load())[[NSNotificationCenter defaultCenter] postNotificationName:@"ReactServerMessage25" object:nil userInfo:@{@"text":message,@"received":@(received)}];
    });
    }
}
