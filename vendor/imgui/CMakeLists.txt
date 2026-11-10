# Builds Dear ImGui (docking) with its C API from dear_bindings and the SDL3
# and SDL_GPU backends into one static library, named where imgui.odin and
# the backend bindings look for it. Driven by `task deps:imgui`; see
# Taskfile.deps.yml for the inputs.
#
#   IMGUI_DIR      ImGui sources (a checkout of the pinned tag)
#   GENERATED_DIR  dcimgui.cpp/.h from dear_bindings
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
	${IMGUI_DIR}/backends/imgui_impl_sdl3.cpp
	${IMGUI_DIR}/backends/imgui_impl_sdlgpu3.cpp
)
target_include_directories(imgui PRIVATE ${IMGUI_DIR} ${IMGUI_DIR}/backends ${GENERATED_DIR} ${SDL3_INCLUDE})
target_compile_definitions(imgui PRIVATE
	IMGUI_DISABLE_OBSOLETE_FUNCTIONS
	IMGUI_DISABLE_OBSOLETE_KEYIO
	"IMGUI_IMPL_API=extern \"C\""
)
set_target_properties(imgui PROPERTIES OUTPUT_NAME ${OUTPUT_NAME} PREFIX "")
