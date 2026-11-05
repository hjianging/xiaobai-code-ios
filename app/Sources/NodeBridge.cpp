#include "NodeBridge.h"

// libnode.a 里的入口是 C++ 符号 node::Start（nodejs-mobile 的 NodeMobile.cpp 也是这么包的）
namespace node {
int Start(int argc, char *argv[]);
}

extern "C" int xiaobai_node_start(int argc, char *argv[]) {
  return node::Start(argc, argv);
}
