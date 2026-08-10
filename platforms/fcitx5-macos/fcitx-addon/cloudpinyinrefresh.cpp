#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#include <fcitx-utils/event.h>
#include <fcitx-utils/eventloopinterface.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/standardpaths.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>

namespace fcitx {
namespace {

constexpr uint64_t PollIntervalUsec = 25'000;

struct FileSnapshot {
  bool exists = false;
  dev_t device = 0;
  ino_t inode = 0;
  off_t size = 0;
  time_t modifiedSeconds = 0;
  long modifiedNanoseconds = 0;

  bool operator==(const FileSnapshot &) const = default;
};

FileSnapshot snapshot(const std::filesystem::path &path) {
  struct stat value{};
  if (::stat(path.c_str(), &value) != 0) {
    return {};
  }
  return {
      true,
      value.st_dev,
      value.st_ino,
      value.st_size,
      value.st_mtimespec.tv_sec,
      value.st_mtimespec.tv_nsec,
  };
}

uint64_t epochMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

} // namespace

class CloudPinyinRefresh final : public AddonInstance {
public:
  explicit CloudPinyinRefresh(Instance *instance) : instance_(instance) {
    const auto rimeDirectory =
        StandardPaths::global().userDirectory(StandardPathsType::PkgData) /
        "rime";
    responsePath_ = rimeDirectory / "cloud_pinyin_async.response";
    statusPath_ = rimeDirectory / "cloud_pinyin_async.bridge";
    responseSnapshot_ = snapshot(responsePath_);
    writeStatus("ready");

    timer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + PollIntervalUsec, 1'000,
        [this](EventSourceTime *source, uint64_t) {
          source->setNextInterval(PollIntervalUsec);
          source->setOneShot();
          poll();
          return true;
        });
    FCITX_INFO() << "Cloud pinyin refresh bridge is ready.";
  }

private:
  void poll() {
    const auto current = snapshot(responsePath_);
    if (current == responseSnapshot_) {
      return;
    }
    responseSnapshot_ = current;
    if (!current.exists || current.size == 0) {
      return;
    }

    auto *inputContext = instance_->lastFocusedInputContext();
    if (!inputContext || !inputContext->hasFocus() ||
        instance_->inputMethod(inputContext) != "rime") {
      writeStatus("ignored");
      return;
    }

    auto *engine = instance_->inputMethodEngine(inputContext);
    const auto *entry = instance_->inputMethodEntry(inputContext);
    if (!engine || !entry) {
      writeStatus("ignored");
      return;
    }

    // Call only the active input-method engine. This private F24 never
    // enters the macOS event stream and cannot leak to the frontmost app.
    KeyEvent event(inputContext, Key(FcitxKey_F24));
    engine->keyEvent(*entry, event);
    ++refreshCount_;
    writeStatus("injected");
  }

  void writeStatus(const char *state) const {
    std::ofstream stream(statusPath_, std::ios::trunc);
    if (!stream) {
      return;
    }
    stream << epochMilliseconds() << '\t' << state << '\t' << getpid() << '\t'
           << refreshCount_ << '\n';
  }

  Instance *instance_;
  std::filesystem::path responsePath_;
  std::filesystem::path statusPath_;
  FileSnapshot responseSnapshot_;
  uint64_t refreshCount_ = 0;
  std::unique_ptr<EventSourceTime> timer_;
};

class CloudPinyinRefreshFactory final : public AddonFactory {
  AddonInstance *create(AddonManager *manager) override {
    return new CloudPinyinRefresh(manager->instance());
  }
};

} // namespace fcitx

FCITX_ADDON_FACTORY_V2(cloudpinyinrefresh, fcitx::CloudPinyinRefreshFactory);
