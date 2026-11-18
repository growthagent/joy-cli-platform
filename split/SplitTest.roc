SplitTest := [].{}

expect "key: a value that is long enough to show it".split_first(":") == Ok({ before: "key", after: " a value that is long enough to show it" })
expect "key: a value long enough".split_first(":") == Ok({ before: "key", after: " a value long enough" })
expect "key: short".split_first(":") == Ok({ before: "key", after: " short" })
