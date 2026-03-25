import Foundation

final class TileCache {
    private class Node {
        let key: CMTileKey
        var value: [CMElementHeader]
        var prev: Node?
        var next: Node?
        
        init(key: CMTileKey, value: [CMElementHeader]) {
            self.key = key
            self.value = value
        }
    }
    
    private let capacity: Int
    private var dict: [CMTileKey: Node] = [:]
    private var head: Node?
    private var tail: Node?
    
    init(capacity: Int) {
        self.capacity = capacity
    }
    
    func get(_ key: CMTileKey) -> [CMElementHeader]? {
        guard let node = dict[key] else { return nil }
        moveToHead(node)
        return node.value
    }
    
    func put(_ key: CMTileKey, headers: [CMElementHeader]) {
        if let node = dict[key] {
            node.value = headers
            moveToHead(node)
        } else {
            let node = Node(key: key, value: headers)
            dict[key] = node
            addToHead(node)
            _ = evictIfNeeded()
        }
    }
    
    func remove(_ key: CMTileKey) {
        guard let node = dict[key] else { return }
        removeNode(node)
        dict[key] = nil
    }
    
    func removeAll() {
        dict.removeAll()
        head = nil
        tail = nil
    }
    
    @discardableResult
    func evictIfNeeded() -> [CMTileKey] {
        var evictedKeys: [CMTileKey] = []
        while dict.count > capacity, let tailNode = tail {
            evictedKeys.append(tailNode.key)
            removeNode(tailNode)
            dict[tailNode.key] = nil
        }
        return evictedKeys
    }
    
    // MARK: - Private Helpers
    
    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        removeNode(node)
        addToHead(node)
    }
    
    private func addToHead(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil {
            tail = node
        }
    }
    
    private func removeNode(_ node: Node) {
        let prev = node.prev
        let next = node.next
        
        if let prev = prev {
            prev.next = next
        } else {
            head = next
        }
        
        if let next = next {
            next.prev = prev
        } else {
            tail = prev
        }
        
        node.prev = nil
        node.next = nil
    }
}
