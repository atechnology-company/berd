# BerdCore

C++ core backend for Berd AI chat application.

## Features

- **Cactus Compute Integration**: Efficient on-device AI inference using Cactus
- **Supported Models**: Gemma 3 1B Q4, Qwen 4B Q4
- **Perplexity Search**: Web search integration with result parsing
- **Conversation Management**: JSON-based message handling
- **Markdown Processing**: Parse and render markdown (extensible)
- **Cross-Platform**: macOS, iOS, Linux (via Swift/C++ FFI)

## Dependencies

### Required

1. **Cactus Compute**
   ```bash
   git clone https://github.com/cactus-compute/cactus.git
   cd cactus
   # Follow build instructions
   ```

2. **libcurl** (HTTP requests)
   ```bash
   # macOS
   brew install curl
   
   # Linux
   sudo apt-get install libcurl4-openssl-dev
   ```

3. **jsoncpp** (JSON parsing)
   ```bash
   # macOS
   brew install jsoncpp
   
   # Linux
   sudo apt-get install libjsoncpp-dev
   ```

## Building

### macOS/Linux

```bash
mkdir build && cd build
cmake ..
make -j$(nproc)
sudo make install
```

### iOS (via Xcode)

1. Add `berdcore` as a subdirectory in your Xcode project
2. Link against `libberdcore.a`
3. Add bridging header (see example below)

## Usage Example

### C++

```cpp
#include <berdcore.h>

// Initialize model
berdcore_model_t model = berdcore_init_model(
    BERDCORE_MODEL_GEMMA3_1B_Q4,
    "/path/to/model/weights",
    2048,  // context size
    [](float progress, void* ud) {
        printf("Loading: %.0f%%\n", progress * 100);
    },
    nullptr
);

// Generate text
berdcore_inference_options_t opts = {
    .temperature = 0.7f,
    .top_p = 0.95f,
    .top_k = 40,
    .max_tokens = 512,
    .stop_sequences = "[\"<|im_end|>\"]"
};

const char* messages = R"([
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is the capital of France?"}
])";

berdcore_generate(model, messages, &opts, 
    [](const char* token, void* ud) {
        printf("%s", token);
        fflush(stdout);
    },
    nullptr
);

// Clean up
berdcore_free_model(model);
```

### Swift (via FFI)

```swift
import Foundation

// Load model
let model = berdcore_init_model(
    BERDCORE_MODEL_GEMMA3_1B_Q4,
    "/path/to/model",
    2048,
    { progress, userData in
        print("Loading: \(Int(progress * 100))%")
    },
    nil
)

// Generate
var options = berdcore_inference_options_t(
    temperature: 0.7,
    top_p: 0.95,
    top_k: 40,
    max_tokens: 512,
    stop_sequences: "[\"<|im_end|>\"]"
)

let messages = """
[
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello!"}
]
"""

berdcore_generate(model, messages, &options, { token, userData in
    if let token = token {
        print(String(cString: token), terminator: "")
    }
}, nil)

berdcore_free_model(model)
```

## API Reference

### Model Management

- `berdcore_init_model()` - Load Cactus model
- `berdcore_free_model()` - Free model resources
- `berdcore_model_is_ready()` - Check if loaded
- `berdcore_model_get_progress()` - Get loading progress

### Inference

- `berdcore_generate()` - Generate text with chat messages
- `berdcore_generate_with_system()` - Generate with system prompt helper

### Search

- `berdcore_search()` - Search via Perplexity API
- `berdcore_fetch_page()` - Fetch webpage content
- `berdcore_create_augmented_prompt()` - Create RAG prompt

### Conversations

- `berdcore_conversation_create()` - New conversation
- `berdcore_conversation_add_message()` - Add message
- `berdcore_conversation_to_json()` - Export to JSON

### Utilities

- `berdcore_version()` - Get library version
- `berdcore_get_last_error()` - Get last error message
- `berdcore_set_log_level()` - Set verbosity

## Model Setup

### Download Models

```bash
# Create models directory
mkdir -p ~/Documents/Models

# Gemma 3 1B Q4 (via Cactus)
cd ~/Documents/Models
# Download from Cactus-compatible source
# See: https://github.com/cactus-compute/cactus

# Qwen 4B Q4
# Similar process for Qwen model
```

### Model Paths

Models should be in Cactus weight format:
```
model_folder/
├── config.json
├── tokenizer.json
├── weights.bin (quantized)
└── metadata.json
```

## Architecture

```
┌─────────────────────────────┐
│     Swift UI (berd app)     │
└──────────────┬──────────────┘
               │ FFI
┌──────────────▼──────────────┐
│       berdcore (C++)        │
│  ┌───────────────────────┐  │
│  │   Model Management    │  │
│  │   (Cactus integration)│  │
│  └───────────────────────┘  │
│  ┌───────────────────────┐  │
│  │  Search & Web Scrape  │  │
│  │  (Perplexity + curl)  │  │
│  └───────────────────────┘  │
│  ┌───────────────────────┐  │
│  │  Conversation Manager │  │
│  └───────────────────────┘  │
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│    Cactus Inference Engine  │
│  ┌───────────────────────┐  │
│  │   Transformer Graph   │  │
│  └───────────────────────┘  │
│  ┌───────────────────────┐  │
│  │   ARM SIMD Kernels    │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

## Performance

| Model | Size | Tokens/sec (M3) | Tokens/sec (iPhone 15) |
|-------|------|-----------------|------------------------|
| Gemma 3 1B Q4 | 650MB | 60-70 | 40-50 |
| Qwen 4B Q4 | 2.3GB | 25-35 | 15-25 |

## License

See LICENSE file.

## Contributing

1. Fork the repo
2. Create feature branch
3. Add tests
4. Submit PR

## Support

- Issues: https://github.com/atechnology-company/berd/issues
- Cactus Docs: https://www.cactuscompute.com/docs/cpp
- Discord: https://discord.gg/nPGWGxXSwr
