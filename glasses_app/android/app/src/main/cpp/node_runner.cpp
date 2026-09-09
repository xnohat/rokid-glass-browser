#include <jni.h>
#include <node.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

extern "C" JNIEXPORT jint JNICALL
Java_com_rokid_rokid_1browser_1glasses_NodeService_startNode(
        JNIEnv* env, jclass, jobjectArray jargs, jstring jcwd,
        jstring jout, jstring jerr) {
    const char* cwd = env->GetStringUTFChars(jcwd, nullptr);
    const char* out = env->GetStringUTFChars(jout, nullptr);
    const char* err = env->GetStringUTFChars(jerr, nullptr);
    if (!cwd || !out || !err) return -1;

    int savedOut = dup(STDOUT_FILENO), savedErr = dup(STDERR_FILENO);
    int outFd = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    int errFd = open(err, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (outFd < 0 || errFd < 0 || chdir(cwd) != 0) {
        if (outFd >= 0) close(outFd); if (errFd >= 0) close(errFd);
        env->ReleaseStringUTFChars(jcwd, cwd);
        env->ReleaseStringUTFChars(jout, out);
        env->ReleaseStringUTFChars(jerr, err);
        return -1;
    }
    dup2(outFd, STDOUT_FILENO); dup2(errFd, STDERR_FILENO);
    close(outFd); close(errFd);

    const jsize argc = env->GetArrayLength(jargs);
    std::vector<std::string> strings;
    strings.reserve(argc);
    size_t total = 0;
    for (jsize i = 0; i < argc; ++i) {
        auto js = static_cast<jstring>(env->GetObjectArrayElement(jargs, i));
        const char* s = env->GetStringUTFChars(js, nullptr);
        strings.emplace_back(s ? s : ""); total += strings.back().size() + 1;
        if (s) env->ReleaseStringUTFChars(js, s);
        env->DeleteLocalRef(js);
    }
    // node::Start requires argv strings in one contiguous writable allocation.
    std::vector<char> storage(total);
    std::vector<char*> argv(argc);
    size_t pos = 0;
    for (jsize i = 0; i < argc; ++i) {
        argv[i] = storage.data() + pos;
        std::memcpy(argv[i], strings[i].c_str(), strings[i].size() + 1);
        pos += strings[i].size() + 1;
    }

    int code = -1;
    try { code = node::Start(argc, argv.data()); }
    catch (...) { std::fprintf(stderr, "node::Start threw\n"); code = -1; }
    std::fflush(stdout); std::fflush(stderr); fsync(STDOUT_FILENO); fsync(STDERR_FILENO);
    if (savedOut >= 0) { dup2(savedOut, STDOUT_FILENO); close(savedOut); }
    if (savedErr >= 0) { dup2(savedErr, STDERR_FILENO); close(savedErr); }
    env->ReleaseStringUTFChars(jcwd, cwd);
    env->ReleaseStringUTFChars(jout, out);
    env->ReleaseStringUTFChars(jerr, err);
    return code;
}
