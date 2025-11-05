#include "berdcore.h"
#include <cactus.h>
#include <string>
#include <vector>
#include <memory>
#include <sstream>
#include <mutex>
#include <atomic>
#include <cstring>
#include <curl/curl.h>
#include <json/json.h>

// ============================================================================
// INTERNAL STRUCTURES
// ============================================================================

struct BerdCoreModel {
    berdcore_model_type_t type;
    cactus_model_t cactus_model;
    std::atomic<float> load_progress;
    bool is_ready;
    int context_size;
    std::string model_path;
    
    BerdCoreModel() : type(BERDCORE_MODEL_GEMMA3_1B_Q4), cactus_model(nullptr), 
                      load_progress(0.0f), is_ready(false), context_size(2048) {}
};

struct BerdCoreConversation {
    std::string title;
    std::vector<std::pair<std::string, std::string>> messages; // role, content
    
    BerdCoreConversation(const char* t) : title(t ? t : "New Conversation") {}
};

// Global error state
static thread_local std::string g_last_error;
static std::atomic<int> g_log_level(2); // default: warn

// Helper: Set error
static void set_error(const std::string& err) {
    g_last_error = err;
    if (g_log_level >= 1) {
        fprintf(stderr, "[BERDCORE ERROR] %s\n", err.c_str());
    }
}

// Helper: Log
static void log_info(const std::string& msg) {
    if (g_log_level >= 3) {
        printf("[BERDCORE INFO] %s\n", msg.c_str());
    }
}

// ============================================================================
// MODEL MANAGEMENT (Cactus Compute)
// ============================================================================

berdcore_model_t berdcore_init_model(
    berdcore_model_type_t model_type,
    const char* model_path,
    int context_size,
    berdcore_progress_callback_t progress_callback,
    void* user_data
) {
    if (!model_path) {
        set_error("Model path cannot be null");
        return nullptr;
    }
    
    auto model = std::make_unique<BerdCoreModel>();
    model->type = model_type;
    model->model_path = model_path;
    model->context_size = context_size > 0 ? context_size : 2048;
    
    log_info("Initializing Cactus model: " + std::string(model_path));
    
    // Initialize Cactus model
    model->load_progress = 0.1f;
    if (progress_callback) {
        progress_callback(0.1f, user_data);
    }
    
    model->cactus_model = cactus_init(model_path, model->context_size);
    if (!model->cactus_model) {
        set_error("Failed to initialize Cactus model");
        return nullptr;
    }
    
    model->load_progress = 0.5f;
    if (progress_callback) {
        progress_callback(0.5f, user_data);
    }
    
    // Model is ready
    model->is_ready = true;
    model->load_progress = 1.0f;
    if (progress_callback) {
        progress_callback(1.0f, user_data);
    }
    
    log_info("Cactus model loaded successfully");
    return model.release();
}

void berdcore_free_model(berdcore_model_t model) {
    if (!model) return;
    
    auto m = static_cast<BerdCoreModel*>(model);
    if (m->cactus_model) {
        cactus_destroy(m->cactus_model);
    }
    delete m;
}

int berdcore_model_is_ready(berdcore_model_t model) {
    if (!model) return 0;
    return static_cast<BerdCoreModel*>(model)->is_ready ? 1 : 0;
}

float berdcore_model_get_progress(berdcore_model_t model) {
    if (!model) return 0.0f;
    return static_cast<BerdCoreModel*>(model)->load_progress.load();
}

// ============================================================================
// INFERENCE
// ============================================================================

berdcore_error_t berdcore_generate(
    berdcore_model_t model,
    const char* messages,
    const berdcore_inference_options_t* options,
    berdcore_token_callback_t token_callback,
    void* user_data
) {
    if (!model || !messages || !token_callback) {
        set_error("Invalid parameters for generate");
        return BERDCORE_ERROR_INVALID_PARAM;
    }
    
    auto m = static_cast<BerdCoreModel*>(model);
    if (!m->is_ready) {
        set_error("Model not ready");
        return BERDCORE_ERROR_NOT_INITIALIZED;
    }
    
    // Build options JSON
    std::ostringstream opts;
    opts << "{";
    opts << "\"temperature\": " << (options ? options->temperature : 0.7f) << ",";
    opts << "\"top_p\": " << (options ? options->top_p : 0.95f) << ",";
    opts << "\"top_k\": " << (options ? options->top_k : 40) << ",";
    opts << "\"max_tokens\": " << (options ? options->max_tokens : 512);
    if (options && options->stop_sequences) {
        opts << ",\"stop_sequences\": " << options->stop_sequences;
    }
    opts << "}";
    
    std::string options_str = opts.str();
    
    // Buffer for response
    char response_buffer[8192];
    memset(response_buffer, 0, sizeof(response_buffer));
    
    // Call Cactus complete with streaming callback
    auto cactus_callback = [](const char* token, uint32_t token_id, void* ud) {
        auto cb_data = static_cast<std::pair<berdcore_token_callback_t, void*>*>(ud);
        cb_data->first(token, cb_data->second);
    };
    
    std::pair<berdcore_token_callback_t, void*> cb_data{token_callback, user_data};
    
    int result = cactus_complete(
        m->cactus_model,
        messages,
        response_buffer,
        sizeof(response_buffer),
        options_str.c_str(),
        nullptr, // no tools
        cactus_callback,
        &cb_data
    );
    
    if (result != 0) {
        set_error("Cactus inference failed with code: " + std::to_string(result));
        return BERDCORE_ERROR_INFERENCE_FAILED;
    }
    
    return BERDCORE_SUCCESS;
}

berdcore_error_t berdcore_generate_with_system(
    berdcore_model_t model,
    const char* system_prompt,
    const char* user_message,
    const berdcore_inference_options_t* options,
    berdcore_token_callback_t token_callback,
    void* user_data
) {
    if (!system_prompt || !user_message) {
        set_error("Invalid prompts");
        return BERDCORE_ERROR_INVALID_PARAM;
    }
    
    // Build messages JSON
    std::ostringstream msgs;
    msgs << "[";
    msgs << "{\"role\":\"system\",\"content\":\"" << system_prompt << "\"},";
    msgs << "{\"role\":\"user\",\"content\":\"" << user_message << "\"}";
    msgs << "]";
    
    std::string messages_str = msgs.str();
    return berdcore_generate(model, messages_str.c_str(), options, token_callback, user_data);
}

// ============================================================================
// PERPLEXITY SEARCH (using libcurl)
// ============================================================================

// CURL write callback
static size_t berdcore_curl_write_callback(void* contents, size_t size, size_t nmemb, void* userp) {
    ((std::string*)userp)->append((char*)contents, size * nmemb);
    return size * nmemb;
}

berdcore_error_t berdcore_search(
    const char* api_key,
    const char* query,
    int max_results,
    berdcore_search_result_t** results,
    int* num_results
) {
    if (!api_key || !query || !results || !num_results) {
        set_error("Invalid search parameters");
        return BERDCORE_ERROR_INVALID_PARAM;
    }
    
    // Build request JSON
    Json::Value request;
    request["query"] = query;
    request["max_results"] = max_results;
    request["max_tokens_per_page"] = 1024;
    
    Json::StreamWriterBuilder writer;
    std::string request_body = Json::writeString(writer, request);
    
    // Make HTTP request
    CURL* curl = curl_easy_init();
    if (!curl) {
        set_error("Failed to initialize CURL");
        return BERDCORE_ERROR_NETWORK;
    }
    
    std::string response_data;
    struct curl_slist* headers = nullptr;
    headers = curl_slist_append(headers, ("Authorization: Bearer " + std::string(api_key)).c_str());
    headers = curl_slist_append(headers, "Content-Type: application/json");
    
    curl_easy_setopt(curl, CURLOPT_URL, "https://api.perplexity.ai/search");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request_body.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, berdcore_curl_write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_data);
    
    CURLcode res = curl_easy_perform(curl);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    
    if (res != CURLE_OK) {
        set_error("CURL request failed: " + std::string(curl_easy_strerror(res)));
        return BERDCORE_ERROR_NETWORK;
    }
    
    // Parse response
    Json::CharReaderBuilder reader;
    Json::Value response;
    std::istringstream iss(response_data);
    std::string errs;
    
    if (!Json::parseFromStream(reader, iss, &response, &errs)) {
        set_error("Failed to parse search response: " + errs);
        return BERDCORE_ERROR_NETWORK;
    }
    
    // Extract results
    const Json::Value& search_results = response["results"];
    *num_results = search_results.size();
    *results = new berdcore_search_result_t[*num_results];
    
    for (int i = 0; i < *num_results; i++) {
        const auto& result = search_results[i];
        (*results)[i].title = strdup(result["title"].asString().c_str());
        (*results)[i].url = strdup(result["url"].asString().c_str());
        (*results)[i].snippet = strdup(result["snippet"].asString().c_str());
    }
    
    return BERDCORE_SUCCESS;
}

void berdcore_free_search_results(berdcore_search_result_t* results, int num_results) {
    if (!results) return;
    for (int i = 0; i < num_results; i++) {
        free(results[i].title);
        free(results[i].url);
        free(results[i].snippet);
    }
    delete[] results;
}

berdcore_error_t berdcore_fetch_page(
    const char* url,
    char** content,
    size_t* content_length
) {
    if (!url || !content || !content_length) {
        return BERDCORE_ERROR_INVALID_PARAM;
    }
    
    CURL* curl = curl_easy_init();
    if (!curl) {
        return BERDCORE_ERROR_NETWORK;
    }
    
    std::string page_data;
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, berdcore_curl_write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &page_data);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Mozilla/5.0");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
    
    CURLcode res = curl_easy_perform(curl);
    curl_easy_cleanup(curl);
    
    if (res != CURLE_OK) {
        set_error("Failed to fetch page");
        return BERDCORE_ERROR_NETWORK;
    }
    
    // Simple HTML stripping (basic implementation)
    // TODO: Use proper HTML parser for production
    *content_length = page_data.length();
    *content = strdup(page_data.c_str());
    
    return BERDCORE_SUCCESS;
}

char* berdcore_create_augmented_prompt(
    const char* original_query,
    const berdcore_search_result_t* results,
    int num_results,
    const char** fetched_content,
    int num_fetched
) {
    std::ostringstream prompt;
    prompt << original_query << "\n\n---\n";
    prompt << "CONTEXT FROM WEB SEARCH:\n\n";
    
    for (int i = 0; i < num_results; i++) {
        prompt << "[" << (i+1) << "] " << results[i].title << "\n";
        prompt << "URL: " << results[i].url << "\n";
        
        if (i < num_fetched && fetched_content[i]) {
            std::string content = fetched_content[i];
            if (content.length() > 800) {
                content = content.substr(0, 800) + "...";
            }
            prompt << "Content: " << content << "\n";
        } else {
            prompt << "Snippet: " << results[i].snippet << "\n";
        }
        prompt << "\n";
    }
    
    prompt << "---\n\n";
    prompt << "Please provide a comprehensive answer using the above sources. ";
    prompt << "Include relevant citations using [1], [2], etc.";
    
    return strdup(prompt.str().c_str());
}

// ============================================================================
// MARKDOWN PROCESSING
// ============================================================================

char* berdcore_markdown_to_html(const char* markdown) {
    // TODO: Implement proper markdown parser
    // For now, return copy
    return markdown ? strdup(markdown) : nullptr;
}

berdcore_error_t berdcore_extract_code_blocks(
    const char* markdown,
    char*** languages,
    char*** codes,
    int* num_blocks
) {
    // TODO: Implement code block extraction
    if (num_blocks) *num_blocks = 0;
    return BERDCORE_SUCCESS;
}

void berdcore_free_string(char* str) {
    if (str) free(str);
}

// ============================================================================
// CONVERSATION MANAGEMENT
// ============================================================================

berdcore_conversation_t berdcore_conversation_create(const char* title) {
    return new BerdCoreConversation(title);
}

berdcore_error_t berdcore_conversation_add_message(
    berdcore_conversation_t conv,
    const char* role,
    const char* content
) {
    if (!conv || !role || !content) {
        return BERDCORE_ERROR_INVALID_PARAM;
    }
    
    auto c = static_cast<BerdCoreConversation*>(conv);
    c->messages.emplace_back(role, content);
    return BERDCORE_SUCCESS;
}

char* berdcore_conversation_to_json(berdcore_conversation_t conv) {
    if (!conv) return nullptr;
    
    auto c = static_cast<BerdCoreConversation*>(conv);
    Json::Value messages(Json::arrayValue);
    
    for (const auto& msg : c->messages) {
        Json::Value message;
        message["role"] = msg.first;
        message["content"] = msg.second;
        messages.append(message);
    }
    
    Json::StreamWriterBuilder writer;
    std::string json_str = Json::writeString(writer, messages);
    return strdup(json_str.c_str());
}

void berdcore_conversation_free(berdcore_conversation_t conv) {
    if (!conv) return;
    delete static_cast<BerdCoreConversation*>(conv);
}

// ============================================================================
// UTILITIES
// ============================================================================

const char* berdcore_version(void) {
    static char version[32];
    snprintf(version, sizeof(version), "%d.%d.%d", 
             BERDCORE_VERSION_MAJOR, 
             BERDCORE_VERSION_MINOR, 
             BERDCORE_VERSION_PATCH);
    return version;
}

const char* berdcore_get_last_error(void) {
    return g_last_error.c_str();
}

void berdcore_set_log_level(int level) {
    g_log_level = level;
}
