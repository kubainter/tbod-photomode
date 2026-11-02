// TBOD_PMFov v1.0.0 — live-FOV mirror for TBOD_PhotoMode on patch 3 (CL 265636).
//
// Mechanism (verified live 2026-11-02):
//   APhotoCameraActor embeds an unreflected FMinimalViewInfo at +0x380
//   (struct size 0x890; 0x380+0x890 == 0xC10, exactly where the reflected
//   tail CapturedPlayerController begins). PM entry snapshots the camera
//   into it and the actor's native CalcCamera returns it to the camera
//   manager every frame, so this embedded FOV channel is the rendered FOV
//   authority while the photo actor is the view target. Nothing upstream
//   of it (pcm.DefaultFOV, CameraComponent.FieldOfView, mode stack,
//   ViewTarget.POV) reaches the render.
//
//   While PlayerCameraManager.ViewTarget.Target is a PhotoCameraActor we
//   copy pcm.DefaultFOV (written by the Lua applyFOV slider path) into the
//   embedded FMinimalViewInfo FOV channel:
//       +0x3B0  FOV             (+0x380 + 0x30)
//       +0x3B4  DesiredFOV      (+0x34)
//       +0x3B8  FirstPersonFOV  (+0x38)
//
//   Sanity gate: on first detection all three must read as equal floats in
//   [10,160] — if a game patch shifts the layout we disable the mirror and
//   warn instead of writing into unknown fields. Writes die with the actor
//   on PM exit, so nothing persists (TBOD Rule 8).
//
//   Per-patch maintenance: the only build-specific constant is the struct
//   offset inside the actor (+0x380). The FOV channel (+0x30/+0x34/+0x38)
//   and the PCM offsets are stable UE layout. If the sanity check fires,
//   re-derive the struct offset from a fresh CXXHeaderDump.

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <Windows.h>

#include <cstdint>

#include <Constructs/Loop.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <Helpers/String.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr uint32_t PCM_DEFAULT_FOV = 0x2D0;   // APlayerCameraManager::DefaultFOV
    constexpr uint32_t PCM_VIEW_TARGET = 0x350;   // APlayerCameraManager::ViewTarget; FTViewTarget.Target @ +0x00

    // FOV channel of the embedded FMinimalViewInfo @ PhotoCameraActor+0x380
    constexpr uint32_t PHOTO_FOV         = 0x3B0; // FOV             (+0x30)
    constexpr uint32_t PHOTO_DESIRED_FOV = 0x3B4; // DesiredFOV      (+0x34)
    constexpr uint32_t PHOTO_FP_FOV      = 0x3B8; // FirstPersonFOV  (+0x38)

    constexpr float    FOV_MIN = 10.0f;
    constexpr float    FOV_MAX = 160.0f;
    constexpr uint64_t RESCAN_INTERVAL_MS = 3000;
    constexpr uint32_t SANITY_FAIL_BUDGET = 120;  // frames the layout check may fail before giving up

    enum class FovLayout : uint8_t { Unknown, Ok, Bad };

    uint64_t  g_next_scan_ms = 0;
    UObject*  g_pcm = nullptr;
    UClass*   g_pcm_class = nullptr;
    FovLayout g_layout = FovLayout::Unknown;
    UObject*  g_last_actor = nullptr;
    uint32_t  g_sanity_misses = 0;
    float     g_last_written = -1.0f;

    void log_normal(const wchar_t* msg) { Output::send<LogLevel::Normal>(File::StringViewType(msg)); }
    void log_warn(const wchar_t* msg)   { Output::send<LogLevel::Warning>(File::StringViewType(msg)); }

    bool seh_read_float(const void* address, float& out)
    {
        __try
        {
            out = *static_cast<const float*>(address);
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    bool seh_write_float(void* address, float value)
    {
        __try
        {
            *static_cast<float*>(address) = value;
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    bool has_class(const UObject* object, const wchar_t* name)
    {
        if (!object) return false;
        for (const UStruct* s = object->GetClassPrivate(); s; s = s->GetSuperStruct())
        {
            if (s->GetName() == name) return true;
        }
        return false;
    }

    bool is_live(const UObject* o)
    {
        __try
        {
            return (o->GetObjectFlags() & 0x10) == 0;  // skip RF_ClassDefaultObject
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    // per-frame liveness: cached UClass* must still match; catches free+reuse of the UObject slot
    bool validate(UObject*& obj, const UClass* expected_class)
    {
        if (!obj) return false;
        __try
        {
            if (obj->GetClassPrivate() == expected_class) return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
        }
        obj = nullptr;
        return false;
    }

    void refresh_pcm()
    {
        g_pcm = nullptr;
        g_pcm_class = nullptr;
        UObjectGlobals::ForEachUObject([&](UObject* object, int32_t, int32_t) {
            if (!is_live(object)) return LoopAction::Continue;
            if (has_class(object, L"PlayerCameraManager"))
            {
                g_pcm = object;
                g_pcm_class = object->GetClassPrivate();
                return LoopAction::Break;
            }
            return LoopAction::Continue;
        });
    }

    // view-target actor, freshly read each frame — never a stale pointer
    UObject* photo_actor()
    {
        UObject* actor = nullptr;
        __try
        {
            actor = *reinterpret_cast<UObject**>(reinterpret_cast<uint8_t*>(g_pcm) + PCM_VIEW_TARGET);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return nullptr;
        }
        if (!actor) return nullptr;
        __try
        {
            if (has_class(actor, L"PhotoCameraActor")) return actor;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
        }
        return nullptr;
    }

    bool sanity_check(const UObject* actor)
    {
        const auto* base = reinterpret_cast<const uint8_t*>(actor);
        float fov{}, desired{}, fp{};
        if (!seh_read_float(base + PHOTO_FOV, fov)) return false;
        if (!seh_read_float(base + PHOTO_DESIRED_FOV, desired)) return false;
        if (!seh_read_float(base + PHOTO_FP_FOV, fp)) return false;
        return fov == desired && desired == fp && fov >= FOV_MIN && fov <= FOV_MAX;
    }

    void mirror_fov()
    {
        if (!validate(g_pcm, g_pcm_class)) return;

        UObject* actor = photo_actor();
        if (!actor)
        {
            g_last_actor = nullptr;
            g_sanity_misses = 0;
            g_last_written = -1.0f;
            return;  // PM inactive — nothing to do
        }

        if (actor != g_last_actor)
        {
            g_last_actor = actor;
            g_sanity_misses = 0;
        }

        if (g_layout == FovLayout::Bad) return;

        if (g_layout == FovLayout::Unknown)
        {
            if (sanity_check(actor))
            {
                g_layout = FovLayout::Ok;
                log_normal(STR("[TBOD_PMFov] photo view target detected; FOV layout OK, mirror active\n"));
            }
            else if (++g_sanity_misses >= SANITY_FAIL_BUDGET)
            {
                g_layout = FovLayout::Bad;
                log_warn(STR("[TBOD_PMFov] FOV layout check failed: +0x3B0/0x3B4/0x3B8 are not equal floats in [10,160]; mirror disabled — re-derive offsets for this build\n"));
            }
            return;  // never write before the layout is confirmed
        }

        float def_fov = 0.0f;
        if (!seh_read_float(reinterpret_cast<const uint8_t*>(g_pcm) + PCM_DEFAULT_FOV, def_fov)) return;
        if (def_fov < FOV_MIN || def_fov > FOV_MAX || def_fov == g_last_written) return;

        auto* base = reinterpret_cast<uint8_t*>(actor);
        if (seh_write_float(base + PHOTO_FOV, def_fov) &&
            seh_write_float(base + PHOTO_DESIRED_FOV, def_fov) &&
            seh_write_float(base + PHOTO_FP_FOV, def_fov))
        {
            g_last_written = def_fov;
        }
    }
} // namespace

class TbodPmFov : public RC::CppUserModBase
{
public:
    TbodPmFov() : CppUserModBase()
    {
        ModName = STR("TBOD_PMFov");
        ModVersion = STR("1.0.0");
        ModDescription = STR("Mirrors PlayerCameraManager.DefaultFOV into PhotoCameraActor's embedded FMinimalViewInfo FOV channel while PM owns the view target.");
        ModAuthors = STR("local");
        log_normal(STR("[TBOD_PMFov] v1.0.0 loaded (FMinimalViewInfo FOV mirror)\n"));
    }

    ~TbodPmFov() override = default;

    auto on_update() -> void override
    {
        mirror_fov();
        const uint64_t now = GetTickCount64();
        if (now < g_next_scan_ms) return;
        g_next_scan_ms = now + RESCAN_INTERVAL_MS;
        if (!g_pcm) refresh_pcm();
    }
};

#define TBOD_PMFOV_API __declspec(dllexport)
extern "C"
{
    TBOD_PMFOV_API RC::CppUserModBase* start_mod()
    {
        return new TbodPmFov();
    }

    TBOD_PMFOV_API void uninstall_mod(RC::CppUserModBase* mod)
    {
        delete mod;
    }
}
