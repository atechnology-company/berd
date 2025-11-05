#ifndef BERDCORE_H
#define BERDCORE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

// ============================================================================
// BERDCORE - Core Backend for Berd AI Chat
// ============================================================================
// Provides unified interface for:
// - Cactus Compute inference (Gemma 3 1B, Qwen 4B)
// - Perplexity search integration
// - Markdown parsing and rendering
// - Conversation management
// ============================================================================

// Version
#define BERDCORE_VERSION_MAJOR 1
#define BERDCORE_VERSION_MINOR 0
#define BERDCORE_VERSION_PATCH 0

// ============================================================================
// TYPES
// ============================================================================

typedef void* berdcore_model_t;
typedef void* berdcore_conversation_t;

// Model types supported via Cactus
typedef enum {
    BERDCORE_MODEL_GEMMA3_1B_Q4 = 0,
    BERDCORE_MODEL_QWEN_4B_Q4 = 1
} berdcore_model_type_t;

// Inference options
typedef struct {
    float temperature;
    float top_p;
    int top_k;
    int max_tokens;
    const char* stop_sequences;  // JSON array, e.g., ["<|im_end|>"]
} berdcore_inference_options_t;

// Token callback for streaming responses
typedef void (*berdcore_token_callback_t)(const char* token, void* user_data);

// Progress callback for model loading
typedef void (*berdcore_progress_callback_t)(float progress, void* user_data);

// Error codes
typedef enum {
    BERDCORE_SUCCESS = 0,
    BERDCORE_ERROR_INVALID_PARAM = -1,
    BERDCORE_ERROR_MODEL_LOAD_FAILED = -2,
    BERDCORE_ERROR_INFERENCE_FAILED = -3,
    BERDCORE_ERROR_OUT_OF_MEMORY = -4,
    BERDCORE_ERROR_NETWORK = -5,
    BERDCORE_ERROR_NOT_INITIALIZED = -6
} berdcore_error_t;

// ============================================================================
// MODEL MANAGEMENT (Cactus Compute)
// ============================================================================

/**
 * Initialize a Cactus model for inference
 * 
 * @param model_type Which model to load (Gemma3-1B-Q4 or Qwen-4B-Q4)
 * @param model_path Path to the Cactus model weights folder
 * @param context_size Maximum context size (default: 2048)
 * @param progress_callback Optional callback for loading progress
 * @param user_data User data passed to callback
 * @return Model handle or NULL on failure
 */
berdcore_model_t berdcore_init_model(
    berdcore_model_type_t model_type,
    const char* model_path,
    int context_size,
    berdcore_progress_callback_t progress_callback,
    void* user_data
);

/**
 * Free model resources
 */
void berdcore_free_model(berdcore_model_t model);

/**
 * Check if model is loaded and ready
 */
int berdcore_model_is_ready(berdcore_model_t model);

/**
 * Get model loading progress (0.0 - 1.0)
 */
float berdcore_model_get_progress(berdcore_model_t model);

// ============================================================================
// INFERENCE
// ============================================================================

/**
 * Generate text completion using Cactus
 * 
 * @param model Model handle
 * @param messages JSON array of chat messages (OpenAI format)
 * @param options Inference options (temperature, top_p, etc.)
 * @param token_callback Callback for each generated token
 * @param user_data User data passed to callback
 * @return Error code (0 = success)
 */
berdcore_error_t berdcore_generate(
    berdcore_model_t model,
    const char* messages,
    const berdcore_inference_options_t* options,
    berdcore_token_callback_t token_callback,
    void* user_data
);

/**
 * Generate text with system prompt
 */
berdcore_error_t berdcore_generate_with_system(
    berdcore_model_t model,
    const char* system_prompt,
    const char* user_message,
    const berdcore_inference_options_t* options,
    berdcore_token_callback_t token_callback,
    void* user_data
);

// ============================================================================
// PERPLEXITY SEARCH
// ============================================================================

typedef struct {
    char* title;
    char* url;
    char* snippet;
} berdcore_search_result_t;

/**
 * Search the web using Perplexity API
 * 
 * @param api_key Perplexity API key
 * @param query Search query
 * @param max_results Maximum number of results
 * @param results Output array of results (caller must free)
 * @param num_results Number of results returned
 * @return Error code
 */
berdcore_error_t berdcore_search(
    const char* api_key,
    const char* query,
    int max_results,
    berdcore_search_result_t** results,
    int* num_results
);

/**
 * Free search results
 */
void berdcore_free_search_results(berdcore_search_result_t* results, int num_results);

/**
 * Fetch webpage content (simple HTML stripping)
 */
berdcore_error_t berdcore_fetch_page(
    const char* url,
    char** content,
    size_t* content_length
);

/**
 * Create augmented prompt with search results
 */
char* berdcore_create_augmented_prompt(
    const char* original_query,
    const berdcore_search_result_t* results,
    int num_results,
    const char** fetched_content,
    int num_fetched
);

// ============================================================================
// MARKDOWN PROCESSING
// ============================================================================

/**
 * Parse markdown to HTML
 */
char* berdcore_markdown_to_html(const char* markdown);

/**
 * Extract code blocks from markdown
 */
berdcore_error_t berdcore_extract_code_blocks(
    const char* markdown,
    char*** languages,
    char*** codes,
    int* num_blocks
);

/**
 * Free markdown processing results
 */
void berdcore_free_string(char* str);

// ============================================================================
// CONVERSATION MANAGEMENT
// ============================================================================

/**
 * Create a new conversation
 */
berdcore_conversation_t berdcore_conversation_create(const char* title);

/**
 * Add message to conversation
 */
berdcore_error_t berdcore_conversation_add_message(
    berdcore_conversation_t conv,
    const char* role,  // "user" or "assistant"
    const char* content
);

/**
 * Get conversation as JSON (OpenAI format)
 */
char* berdcore_conversation_to_json(berdcore_conversation_t conv);

/**
 * Free conversation
 */
void berdcore_conversation_free(berdcore_conversation_t conv);

// ============================================================================
// UTILITIES
// ============================================================================

/**
 * Get library version string
 */
const char* berdcore_version(void);

/**
 * Get last error message
 */
const char* berdcore_get_last_error(void);

/**
 * Set log level (0=none, 1=error, 2=warn, 3=info, 4=debug)
 */
void berdcore_set_log_level(int level);

#ifdef __cplusplus
}
#endif

#endif // BERDCORE_H
