#ifndef XIAOBAI_NODE_BRIDGE_H
#define XIAOBAI_NODE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// 启动内嵌 Node（等价于 nodejs-mobile 的 node_start → node::Start）。
/// 该调用会一直占用当前线程跑事件循环，必须放在后台线程。
int xiaobai_node_start(int argc, char *argv[]);

#ifdef __cplusplus
}
#endif

#endif /* XIAOBAI_NODE_BRIDGE_H */
