package me.junjie.xing.flutter_aria2

class Aria2NativeException(
    val code: String,
    message: String
) : RuntimeException(message)
