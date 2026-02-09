#ifdef GL_ES
precision highp float;
#endif

uniform vec3 uLightDir;
uniform vec3 uCameraPos;
uniform vec3 uLightRadiance;
uniform sampler2D uGDiffuse;
uniform sampler2D uGDepth;
uniform sampler2D uGNormalWorld;
uniform sampler2D uGShadow;
uniform sampler2D uGPosWorld;

varying mat4 vWorldToScreen;
varying highp vec4 vPosWorld;

#define M_PI 3.1415926535897932384626433832795
#define TWO_PI 6.283185307
#define INV_PI 0.31830988618
#define INV_TWO_PI 0.15915494309

float Rand1(inout float p) {
  p = fract(p * .1031);
  p *= p + 33.33;
  p *= p + p;
  return fract(p);
}

vec2 Rand2(inout float p) {
  return vec2(Rand1(p), Rand1(p));
}

float InitRand(vec2 uv) {
	vec3 p3  = fract(vec3(uv.xyx) * .1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

vec3 SampleHemisphereUniform(inout float s, out float pdf) {
  vec2 uv = Rand2(s);
  float z = uv.x;
  float phi = uv.y * TWO_PI;
  float sinTheta = sqrt(1.0 - z*z);
  vec3 dir = vec3(sinTheta * cos(phi), sinTheta * sin(phi), z);
  pdf = INV_TWO_PI;
  return dir;
}

vec3 SampleHemisphereCos(inout float s, out float pdf) {
  vec2 uv = Rand2(s);
  float z = sqrt(1.0 - uv.x);
  float phi = uv.y * TWO_PI;
  float sinTheta = sqrt(uv.x);
  vec3 dir = vec3(sinTheta * cos(phi), sinTheta * sin(phi), z);
  pdf = z * INV_PI;
  return dir;
}

void LocalBasis(vec3 n, out vec3 b1, out vec3 b2) {
  float sign_ = sign(n.z);
  if (n.z == 0.0) {
    sign_ = 1.0;
  }
  float a = -1.0 / (sign_ + n.z);
  float b = n.x * n.y * a;
  b1 = vec3(1.0 + sign_ * n.x * n.x * a, sign_ * b, -sign_ * n.x);
  b2 = vec3(b, sign_ + n.y * n.y * a, -n.y);
}

vec4 Project(vec4 a) {
  return a / a.w;
}

float GetDepth(vec3 posWorld) {
  float depth = (vWorldToScreen * vec4(posWorld, 1.0)).w;
  return depth;
}

/*
 * Transform point from world space to screen space([0, 1] x [0, 1])
 *
 */
vec2 GetScreenCoordinate(vec3 posWorld) {
  vec2 uv = Project(vWorldToScreen * vec4(posWorld, 1.0)).xy * 0.5 + 0.5;
  return uv;
}

float GetGBufferDepth(vec2 uv) {
  float depth = texture2D(uGDepth, uv).x;
  if (depth < 1e-2) {
    depth = 1000.0;
  }
  return depth;
}

vec3 GetGBufferNormalWorld(vec2 uv) {
  vec3 normal = texture2D(uGNormalWorld, uv).xyz;
  return normal;
}

vec3 GetGBufferPosWorld(vec2 uv) {
  vec3 posWorld = texture2D(uGPosWorld, uv).xyz;
  return posWorld;
}

float GetGBufferuShadow(vec2 uv) {
  float visibility = texture2D(uGShadow, uv).x;
  return visibility;
}

vec3 GetGBufferDiffuse(vec2 uv) {
  vec3 diffuse = texture2D(uGDiffuse, uv).xyz;
  diffuse = pow(diffuse, vec3(2.2));
  return diffuse;
}

/*
 * Evaluate diffuse bsdf value.
 *
 * wi, wo are all in world space.
 * uv is in screen space, [0, 1] x [0, 1].
 *
 */
vec3 EvalDiffuse(vec3 wi, vec3 wo, vec2 uv) {
  // 1. 获取漫反射颜色 (Albedo)
  vec3 albedo = GetGBufferDiffuse(uv);
  
  // 2. 获取法线
  vec3 normal = GetGBufferNormalWorld(uv);

  // 3. 计算 Lambertian Diffuse BRDF
  // 公式: albedo / PI * max(0, dot(n, wi))
  // 注意：作业框架可能希望这里只返回 BRDF 本身 (albedo/PI)，
  // 而把 cos theta 项放在积分里乘。但通常 EvalDiffuse 包含了 cos 项。
  // 让我们按照标准渲染方程: Lo = Le + Li * BRDF * cos
  // 这里的函数名是 EvalDiffuse，通常指 f_r * cos_theta
  
  float cosTheta = max(0.0, dot(normal, wi));
  return albedo * INV_PI * cosTheta;
}

/*
 * Evaluate directional light with shadow map
 * uv is in screen space, [0, 1] x [0, 1].
 *
 */
vec3 EvalDirectionalLight(vec2 uv) {
  // 1. 获取光照辐射度 (Radiance)
  vec3 Le = uLightRadiance;

  // 2. 获取可见性 (Shadow Map)
  float visibility = GetGBufferuShadow(uv);

  // 3. 计算 BSDF (Diffuse)
  // uLightDir 指向光源，就是 wi
  // vPosWorld 是当前像素的世界坐标，需要计算 wo (指向相机)
  vec3 wo = normalize(uCameraPos - vPosWorld.xyz);
  vec3 wi = normalize(uLightDir);
  
  vec3 bsdf = EvalDiffuse(wi, wo, uv);

  // 4. 组合
  return Le * visibility * bsdf;
}

bool RayMarch(vec3 ori, vec3 dir, out vec3 hitPos) {
  // 1. 设置步进参数
  float step = 0.8; 
  const int maxSteps = 150;
  
  // 2. 开始步进
  vec3 currentPos = ori;
  for(int i = 0; i < maxSteps; i++) {
    // 往前走一步
    currentPos += dir * step;

    // 3. 将当前世界坐标转为屏幕 UV 坐标
    vec2 uv = GetScreenCoordinate(currentPos);

    // 4. 越界检查 (如果光线跑出屏幕了，就停止)
    if(uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
      return false;
    }

    // 5. 深度测试 (Intersection Test)
    // GBuffer 里的深度 (物体表面的深度)
    float gbufferDepth = GetGBufferDepth(uv);
    
    // 光线当前的深度 (从相机视角看)
    float rayDepth = GetDepth(currentPos);

    // 如果 rayDepth > gbufferDepth，说明光线钻到了物体后面 -> 相交！
    // 注意：这里需要一个阈值，防止把“仅仅是经过物体背后”误判为相交
    // 所以通常判断: rayDepth > gbufferDepth && rayDepth < gbufferDepth + thickness
    if(rayDepth > gbufferDepth && rayDepth < gbufferDepth + 2.0) { 
       hitPos = currentPos;
       return true;
    }
  }

  return false;
}

#define SAMPLE_NUM 1

void main() {
  // 1. 初始化随机数种子
  float s = InitRand(gl_FragCoord.xy);

  vec3 L = vec3(0.0);

  // 2. 计算直接光照 (Direct Lighting)
  vec2 uv = GetScreenCoordinate(vPosWorld.xyz);
  L = EvalDirectionalLight(uv);

  // 3. 计算间接光照 (Indirect Lighting - SSR)
  vec3 L_indirect = vec3(0.0);
  
  vec3 normal = GetGBufferNormalWorld(uv);
  vec3 wo = normalize(uCameraPos - vPosWorld.xyz);
  
  // 构建局部坐标系 (TBN)
  vec3 b1, b2;
  LocalBasis(normal, b1, b2);

  for(int i = 0; i < SAMPLE_NUM; i++) {
    float pdf;
    // 3.1 采样一个方向 (Hemisphere Sampling)
    // 这里使用 Cosine-Weighted 采样，效率更高
    vec3 localDir = SampleHemisphereCos(s, pdf);
    
    // 转换到世界坐标系
    vec3 wi = normalize(localDir.x * b1 + localDir.y * b2 + localDir.z * normal);

    // 3.2 发射光线 (Ray Marching)
    vec3 hitPos;
    if(RayMarch(vPosWorld.xyz, wi, hitPos)) {
      // 3.3 如果击中物体，获取击中点的光照 (L_i)
      // 注意：击中点的光照 = 击中点的直接光照 + 击中点的间接光照
      // 这里为了简化，我们通常只取击中点的 "EvalDiffuse" 或者 "EvalDirectionalLight"
      // 但更准确的做法是查询上一帧的颜色 (Frame Buffer)，但这里没有
      // 作业提示说：EvaluateLight(position1)，我们可以复用 EvalDiffuse + GetGBufferDiffuse
      
      vec2 hitUV = GetScreenCoordinate(hitPos);
      vec3 Li = EvalDirectionalLight(hitUV); // 获取击中点的直接光照作为这里的入射光
      
      // 3.4 渲染方程: L_indir += Li * f_r * cos / pdf
      // 注意：EvalDiffuse 已经包含了 f_r * cos
      // SampleHemisphereCos 的 pdf = cos / PI
      // f_r = albedo / PI * cos
      // 这里的数学约分要小心
      
      vec3 fr = EvalDiffuse(wi, wo, uv);
      
      L_indirect += Li * fr / pdf;
    }
  }
  
  // 平均化间接光
  L_indirect /= float(SAMPLE_NUM);

  // 4. 合并直接光与间接光
  L += L_indirect;

  // Tone Mapping & Gamma Correction
  vec3 color = pow(clamp(L, vec3(0.0), vec3(1.0)), vec3(1.0 / 2.2));
  gl_FragColor = vec4(vec3(color.rgb), 1.0);
}
