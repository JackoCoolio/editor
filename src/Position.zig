const Position = @This();

row: usize = 0,
col: usize = 0,

pub const zero = Position{};

pub fn add(a: Position, b: Position) Position {
    var out = a;
    if (b.row > 0) {
        out.col = b.col;
    } else {
        out.col += b.col;
    }
    out.row += b.row;
    return out;
}

pub fn eq(self: Position, other: Position) bool {
    return self.row == other.row and self.col == other.col;
}

pub fn gt(self: Position, other: Position) bool {
    if (self.row < other.row) {
        return false;
    }

    if (self.row > other.row) {
        return true;
    }

    return self.col > other.col;
}

pub fn lt(self: Position, other: Position) bool {
    return !self.eq(other) and !self.gt(other);
}
