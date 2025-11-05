berd
bird and bard but dumb

An iOS AI chat app featuring Apple Intelligence with Private Cloud Compute, plus local model inference via Cactus Compute API.

## Features

✅ **Apple Intelligence Integration**
- First iOS app to use Apple Intelligence + Private Cloud Compute through Shortcuts
- Automatic fallback when Apple Intelligence is unavailable

✅ **Local Model Inference** (via Cactus Compute)
- Gemma 3 1B (Q4) - Fast and efficient
- Qwen 4B (Q4) - Better reasoning capabilities
- On-device inference optimized for ARM CPUs (battery-efficient)

✅ **Search & Grounding**
- Perplexity API integration for web search
- Automatic grounding of responses with citations

✅ **UI Enhancements**
- Customizable accent colors (10 color options)
- Visual loading progress bar in input field
- Markdown rendering in chat previews
- Swipe gestures for navigation
- SF Symbols 7 icons

✅ **Chat Features**
- Custom prompt support
- Dictation input
- Conversation history
- Streaming token generation

## Architecture

### berdcore (C++ Backend Package)

All non-Apple-Intelligence backend logic is implemented in a separate C++ package called **berdcore**:

- **Model Inference**: Cactus Compute on-device inference for Gemma 3 and Qwen 4B
- **Search Integration**: Perplexity API via libcurl
- **Conversation Management**: JSON-based chat history
- **C API**: Clean FFI interface for Swift consumption

Located in: `/berdcore/`

See [BERDCORE_BUILD.md](./BERDCORE_BUILD.md) for build instructions.

### Swift Frontend

SwiftUI-based UI with SwiftData for persistence:

- `ChatView.swift`: Main chat interface with markdown rendering
- `LocalModelService.swift`: Swift wrapper for berdcore C API
- `AIChatService.swift`: Apple Intelligence integration
- `PerplexityService.swift`: Web search fallback

## Setup

### Prerequisites

1. **Xcode 15+** with Swift 5.9+
2. **CMake 3.20+** for building berdcore
3. **Homebrew** for dependencies

### Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/undivisible/berd.git
   cd berd
   ```

2. **Build berdcore:**
   ```bash
   cd berdcore
   mkdir build && cd build
   
   # Install dependencies
   brew install cmake pkg-config curl jsoncpp
   
   # Configure and build
   cmake .. -DCMAKE_BUILD_TYPE=Release
   make -j$(sysctl -n hw.ncpu)
   ```

3. **Open Xcode project:**
   ```bash
   cd ../..
   open berd.xcodeproj
   ```

4. **Configure API Keys** (if needed):
   - Cactus API: Set in app settings or environment
   - Perplexity API: Add to `PerplexityService.swift`

5. **Build and Run** in Xcode (⌘R)

For detailed build instructions, see [BERDCORE_BUILD.md](./BERDCORE_BUILD.md).

## Configuration

### Model Selection

In Settings → Advanced → Local AI Models:
- **Apple Intelligence**: Uses on-device or Private Cloud Compute  
- **Gemma 3 1B Q4**: Fast local inference via Cactus (on-device)
- **Qwen 4B Q4**: Higher quality local inference via Cactus (on-device)

### Accent Colors

Settings → Appearance:
- Choose from 10 preset colors
- Applies to buttons, highlights, and UI accents

### Custom Prompts

Settings → Prompts:
- Configure system prompts for different use cases
- Adjust temperature, top-p, and other generation parameters

## Technical Details

### C++ Backend (berdcore)

**Dependencies:**
- Cactus Compute SDK (https://cactuscompute.com)
- libcurl (HTTP client)
- jsoncpp (JSON parsing)

**API Highlights:**
```c
// Initialize model with progress tracking
berdcore_model_t* berdcore_init_model(
    berdcore_model_type_t type,
    const char* model_path,
    int context_size,
    berdcore_progress_callback_t progress_callback,
    berdcore_error_callback_t error_callback,
    void* userdata
);

// Generate text with streaming
int berdcore_generate(
    berdcore_model_t* model,
    const char* prompt,
    berdcore_inference_options_t* options,
    berdcore_token_callback_t token_callback,
    void* userdata
);

// Search via Perplexity
int berdcore_search(
    const char* query,
    char* response_buffer,
    int buffer_size,
    int max_results
);
```

### Swift Integration

The `LocalModelService.swift` wraps the berdcore C API:

```swift
let service = LocalModelService()

// Load model
try await service.loadModel(.gemma3_1b_q4)

// Set callbacks
service.onProgress = { progress, message in
    print("Loading: \(progress * 100)%")
}

service.onToken = { token in
    print(token, terminator: "")
}

// Generate text
let response = try await service.generate(
    prompt: "Hello, how are you?",
    temperature: 0.7,
    maxTokens: 2048
)
```

## Roadmap

### Current Scope
- ✅ Text generation with multiple backends
- ✅ Automatic fallback (Apple Intelligence → Cactus → Perplexity)
- ✅ Web search grounding
- ✅ Custom prompts and dictation
- ✅ Accent color customization
- ✅ Markdown rendering

### Planned Features
- [ ] PCC integration through Shortcuts (in progress)
- [ ] Improved UI design and animations
- [ ] Multi-modal support (images, PDFs)
- [ ] Conversation export/import
- [ ] Model download management
- [ ] Advanced prompt engineering tools

## License

idk

## Acknowledgments

- Apple Intelligence team for PCC access
- Cactus Compute for local inference
- Perplexity AI for search capabilities

---

**Note**: Apple Intelligence features require iOS 18+ and compatible hardware.