# Builds Dear ImGui (docking) with its C API from dear_bindings and the SDL3
# and SDL_GPU backends into one static library, named where imgui.odin and
# the backend bindings look for it. Driven by `task deps:imgui`; see
# taskfiles/deps.yml for the inputs.
#
#   IMGUI_DIR      ImGui sources (a checkout of the pinned tag)
#   GENERATED_DIR  dcimgui.cpp/.h and dcimgui_internal.cpp/.h from dear_bindings
#   SDL3_INCLUDE   SDL3 headers (the static SDL3 build's install/include)
#   OUTPUT_NAME    library file name, e.g. imgui_macosx_arm64
cmake_minimum_required(VERSION 3.20)
project(fire_imgui CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded") # as Odin links

add_library(imgui STATIC
	${IMGUI_DIR}/imgui.cpp
	${IMGUI_DIR}/imgui_demo.cpp
	${IMGUI_DIR}/imgui_draw.cpp
	${IMGUI_DIR}/imgui_tables.cpp
	${IMGUI_DIR}/imgui_widgets.cpp
	${GENERATED_DIR}/dcimgui.cpp
	${GENERATED_DIR}/dcimgui_internal.cpp  # the internal API: dock_builder.odin binds a few of it
	${IMGUI_DIR}/backends/imgui_impl_sdl3.cpp
	${IMGUI_DIR}/backends/imgui_impl_sdlgpu3.cpp
	${CMAKE_CURRENT_SOURCE_DIR}/probe.cpp  # the test-engine hooks: app:ui's item probe
)
target_include_directories(imgui PRIVATE ${IMGUI_DIR} ${IMGUI_DIR}/backends ${GENERATED_DIR} ${SDL3_INCLUDE})
target_compile_definitions(imgui PRIVATE
	IMGUI_DISABLE_OBSOLETE_FUNCTIONS
	IMGUI_DISABLE_OBSOLETE_KEYIO
	"IMGUI_IMPL_API=extern \"C\""
)
# The test-engine hooks probe.cpp implements (off at run time until
# enabled), in ImGui's own sources only: the generated C API wraps a hook
# this ImGui doesn't have. The define changes no struct layout (only some
# status flags' names).
set_source_files_properties(
	${IMGUI_DIR}/imgui.cpp ${IMGUI_DIR}/imgui_demo.cpp ${IMGUI_DIR}/imgui_draw.cpp
	${IMGUI_DIR}/imgui_tables.cpp ${IMGUI_DIR}/imgui_widgets.cpp ${CMAKE_CURRENT_SOURCE_DIR}/probe.cpp
	PROPERTIES COMPILE_DEFINITIONS IMGUI_ENABLE_TEST_ENGINE)
set_target_properties(imgui PROPERTIES OUTPUT_NAME ${OUTPUT_NAME} PREFIX "")
