{
    "targets": [
        {
            "target_name": "audio_capture",
            "sources": [
                "src/addon.cpp",
                "src/audio_buffer.mm"
            ],
            "include_dirs": [
                "<!@(node -p \"require('node-addon-api').include\")",
                "./include"
            ],
            "cflags!": [ "-fno-exceptions", "-fno-rtti" ],
            "cflags_cc!": [ "-fno-exceptions", "-fno-rtti" ],
            "defines": [ "NAPI_DISABLE_CPP_EXCEPTIONS" ],
            "conditions": [
                [ 'OS=="mac"', {
                    "xcode_settings": {
                        "CLANG_ENABLE_OBJC_ARC": "YES",
                        "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
                        "GCC_ENABLE_CPP_RTTI": "YES",
                        "MACOSX_DEPLOYMENT_TARGET": "13.0",
                        "OTHER_LDFLAGS": [
                            "-framework", "ApplicationServices",
                            "-framework", "CoreGraphics",
                            "-framework", "CoreFoundation",
                            "-framework", "ScreenCaptureKit"
                        ]
                    }
                }]
            ]
        }
    ]
}