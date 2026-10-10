@abstract
extends Architecture
## 容器型扩展模块基类
## 语义标记：node is Kit 可判定“这是一个容器模块”
## 继承 Architecture 即获得作用域总线、service_config 服务暴露与生命周期闭环
## 当前刻意留空：容器模块的通用操作待实际出现需求时再提炼，避免凭空抽象
class_name Kit