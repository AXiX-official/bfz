const std = @import("std");

/// Segmented Array
pub fn Memory(comptime T: type, comptime blockSize: usize) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        map: []([]T),
        mapSize: usize,
        mapPostiveSize: usize,
        mapCapacity: usize,
        defaultValue: T,
        limitSize: usize,
        blockSize: usize,
        maxIndex: i64 = 0,
        minIndex: i64 = 0,

        pub fn init(alloc: std.mem.Allocator, defaultValue: T, limit: usize) !Self {
            const block0 = try alloc.alloc(T, blockSize);
            @memset(block0, defaultValue);
            const map = try alloc.alloc([]T, 4);
            errdefer alloc.free(map);
            map[0] = block0;
            return Self{ .alloc = alloc, .map = map, .mapSize = 1, .mapPostiveSize = 1, .mapCapacity = 4, .defaultValue = defaultValue, .limitSize = limit, .blockSize = blockSize };
        }

        pub fn deinit(self: Self) void {
            for (0..self.mapPostiveSize) |i| {
                self.alloc.free(self.map[i]);
            }
            for ((self.mapCapacity - (self.mapSize - self.mapPostiveSize))..self.mapCapacity) |i| {
                self.alloc.free(self.map[i]);
            }
            self.alloc.free(self.map);
        }

        pub fn getItem(self: *Self, index: i64) !*T {
            if (index >= 0) {
                self.maxIndex = @max(index, self.maxIndex);
            } else {
                self.minIndex = @min(index, self.minIndex);
            }

            const mapIndex = @divFloor(index, blockSize);

            if (mapIndex >= 0) {
                if (@as(usize, @intCast(mapIndex)) + self.mapSize - self.mapPostiveSize >= self.mapCapacity) {
                    try self.resize(@as(usize, @intCast(mapIndex)) + self.mapSize - self.mapPostiveSize + 1);
                }
                if (mapIndex >= self.mapPostiveSize) {
                    for (self.mapSize..(@as(usize, @intCast(mapIndex + 1)))) |i| {
                        const newBlock = try self.alloc.alloc(T, blockSize);
                        @memset(newBlock, self.defaultValue);
                        self.map[i] = newBlock;
                        self.mapPostiveSize += 1;
                        self.mapSize += 1;
                    }
                }

                const blockIndex = @mod(index, blockSize);
                return &(self.map[@as(usize, @intCast(mapIndex))][@as(usize, @intCast(blockIndex))]);
            } else {
                if (self.mapPostiveSize + @as(usize, @intCast(-mapIndex)) > self.mapCapacity) {
                    try self.resize(self.mapPostiveSize + @as(usize, @intCast(-mapIndex)));
                }
                if (self.mapPostiveSize + @as(usize, @intCast(-mapIndex)) > self.mapSize) {
                    const mapNegetiveSize = self.mapSize - self.mapPostiveSize;
                    for ((self.mapCapacity - @as(usize, @intCast(-mapIndex)))..(self.mapCapacity - mapNegetiveSize)) |i| {
                        const newBlock = try self.alloc.alloc(T, blockSize);
                        @memset(newBlock, self.defaultValue);
                        self.map[i] = newBlock;
                        self.mapSize += 1;
                    }
                }
                const blockIndex = @mod(index, blockSize);
                return &(self.map[self.mapCapacity - @as(usize, @intCast(-mapIndex))][@as(usize, @intCast(blockIndex))]);
            }
        }

        fn resize(self: *Self, newCapacity: usize) !void {
            const deserveCapacity = if (newCapacity > self.mapCapacity * 2) newCapacity else self.mapCapacity * 2;
            const newMap = try self.alloc.alloc([]T, deserveCapacity);
            @memcpy(newMap[0..self.mapPostiveSize], self.map[0..self.mapPostiveSize]);
            const negetiveSize = self.mapSize - self.mapPostiveSize;
            @memcpy(newMap[(deserveCapacity - negetiveSize)..deserveCapacity], self.map[(self.mapCapacity - negetiveSize)..self.mapCapacity]);
            self.alloc.free(self.map);
            self.map = newMap;
            self.mapCapacity = deserveCapacity;
        }
    };
}
