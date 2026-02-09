#ifdef GL_ES
precision mediump float;
#endif

// Phong related variables
uniform sampler2D uSampler;
uniform vec3 uKd;
uniform vec3 uKs;
uniform vec3 uLightPos;
uniform vec3 uCameraPos;
uniform vec3 uLightIntensity;

varying highp vec2 vTextureCoord;
varying highp vec3 vFragPos;
varying highp vec3 vNormal;

// Shadow map related variables
#define NUM_SAMPLES 20
#define BLOCKER_SEARCH_NUM_SAMPLES NUM_SAMPLES
#define PCF_NUM_SAMPLES NUM_SAMPLES
#define NUM_RINGS 10
#define LIGHT_WIDTH_SIZE 10.0

#define EPS 1e-3
#define PI 3.141592653589793
#define PI2 6.283185307179586

uniform sampler2D uShadowMap;

varying vec4 vPositionFromLight;

highp float rand_1to1(highp float x ) { 
  // -1 -1
  return fract(sin(x)*10000.0);
}

highp float rand_2to1(vec2 uv ) { 
  // 0 - 1
	const highp float a = 12.9898, b = 78.233, c = 43758.5453;
	highp float dt = dot( uv.xy, vec2( a,b ) ), sn = mod( dt, PI );
	return fract(sin(sn) * c);
}

float unpack(vec4 rgbaDepth) {
    const vec4 bitShift = vec4(1.0, 1.0/256.0, 1.0/(256.0*256.0), 1.0/(256.0*256.0*256.0));
    return dot(rgbaDepth, bitShift);
}

vec2 poissonDisk[NUM_SAMPLES];

void poissonDiskSamples( const in vec2 randomSeed ) {

  float ANGLE_STEP = PI2 * float( NUM_RINGS ) / float( NUM_SAMPLES );
  float INV_NUM_SAMPLES = 1.0 / float( NUM_SAMPLES );

  float angle = rand_2to1( randomSeed ) * PI2;
  float radius = INV_NUM_SAMPLES;
  float radiusStep = radius;

  for( int i = 0; i < NUM_SAMPLES; i ++ ) {
    poissonDisk[i] = vec2( cos( angle ), sin( angle ) ) * pow( radius, 0.75 );
    radius += radiusStep;
    angle += ANGLE_STEP;
  }
}

void uniformDiskSamples( const in vec2 randomSeed ) {

  float randNum = rand_2to1(randomSeed);
  float sampleX = rand_1to1( randNum ) ;
  float sampleY = rand_1to1( sampleX ) ;

  float angle = sampleX * PI2;
  float radius = sqrt(sampleY);

  for( int i = 0; i < NUM_SAMPLES; i ++ ) {
    poissonDisk[i] = vec2( radius * cos(angle) , radius * sin(angle)  );

    sampleX = rand_1to1( sampleY ) ;
    sampleY = rand_1to1( sampleX ) ;

    angle = sampleX * PI2;
    radius = sqrt(sampleY);
  }
}

// Step 1: 寻找遮挡物 (Blocker Search)
float findBlocker( sampler2D shadowMap,  vec2 uv, float zReceiver ) {
  int blockerNum = 0;
  float blockDepth = 0.0;
  float shadowMapSize = 2048.0;
  
  // 搜索范围一般设为固定值或与 Light Size 相关
  float searchWidth = LIGHT_WIDTH_SIZE / shadowMapSize; 

  poissonDiskSamples(uv);

  for(int i = 0; i < BLOCKER_SEARCH_NUM_SAMPLES; i++){
    vec2 sampleCoord = uv + poissonDisk[i] * searchWidth;
    float closestDepth = unpack(texture2D(shadowMap, sampleCoord));

    // 只有比当前点更浅的才算遮挡物 (zReceiver > closestDepth)
    // 注意 bias
    if(zReceiver - 0.005 > closestDepth){
      blockDepth += closestDepth;
      blockerNum++;
    }
  }

  // 如果没有遮挡物，返回 -1
  if(blockerNum == 0) return -1.0;

  // 返回平均遮挡深度
  return blockDepth / float(blockerNum);
}

float PCF(sampler2D shadowMap, vec4 coords) {
  // 1. 初始化采样参数
  // 纹理坐标变换
  vec3 shadowCoordProj = coords.xyz / coords.w;
  shadowCoordProj = shadowCoordProj * 0.5 + 0.5;
  
  // 生成随机种子 (用于旋转泊松圆盘)
  poissonDiskSamples(shadowCoordProj.xy);

  // filterSize: 滤波核半径 (控制软阴影范围)
  // shadowMapSize: 假设 ShadowMap 大小为 2048x2048
  float textureSize = 2048.0;
  float filterSize = 5.0 / textureSize; // 5个纹理像素的范围

  float visibility = 0.0;
  float currentDepth = shadowCoordProj.z;
  float bias = 0.005;

  // 2. 循环采样 (PCF_NUM_SAMPLES 已定义为 20)
  for(int i = 0; i < PCF_NUM_SAMPLES; i++){
    // 计算采样坐标
    vec2 sampleCoord = shadowCoordProj.xy + poissonDisk[i] * filterSize;
    
    // 读取深度
    float closestDepth = unpack(texture2D(shadowMap, sampleCoord));

    // 累加可见性
    visibility += (currentDepth - bias > closestDepth) ? 0.0 : 1.0;
  }

  // 3. 取平均
  return visibility / float(PCF_NUM_SAMPLES);
}

// PCSS 主函数
float PCSS(sampler2D shadowMap, vec4 coords){
  vec3 shadowCoordProj = coords.xyz / coords.w;
  shadowCoordProj = shadowCoordProj * 0.5 + 0.5;
  
  // 0. 提前结束：如果在 ShadowMap 范围外，不做处理
  if (shadowCoordProj.z > 1.0) return 1.0;

  float zReceiver = shadowCoordProj.z;

  // STEP 1: Blocker Search (计算平均遮挡深度)
  float zBlocker = findBlocker(shadowMap, shadowCoordProj.xy, zReceiver);

  // 如果没有遮挡物，说明完全被照亮，是硬阴影区域但没有阴影
  if(zBlocker < -EPS) return 1.0;

  // STEP 2: Penumbra Size (计算半影大小)
  // 相似三角形公式: W_penumbra = (d_receiver - d_blocker) / d_blocker * W_light
  float penumbraRatio = (zReceiver - zBlocker) / zBlocker;
  float filterRadius = penumbraRatio * LIGHT_WIDTH_SIZE / 2048.0; // 除以纹理大小转为UV空间

  // STEP 3: Filtering (使用计算出的半径进行 PCF)
  // 这里逻辑与 PCF 函数几乎一样，只是 filterSize 是动态的
  float visibility = 0.0;
  float bias = 0.005;

  poissonDiskSamples(shadowCoordProj.xy); // 重新生成随机采样点

  for(int i = 0; i < PCF_NUM_SAMPLES; i++){
    vec2 sampleCoord = shadowCoordProj.xy + poissonDisk[i] * filterRadius;
    float closestDepth = unpack(texture2D(shadowMap, sampleCoord));
    visibility += (zReceiver - bias > closestDepth) ? 0.0 : 1.0;
  }

  return visibility / float(PCF_NUM_SAMPLES);
}


float useShadowMap(sampler2D shadowMap, vec4 shadowCoord){
  // 1. 归一化坐标: [-1, 1] -> [0, 1]
  // shadowCoord 是 vPositionFromLight，已经在 Vertex Shader 中计算好了
  vec3 shadowCoordProj = shadowCoord.xyz / shadowCoord.w;
  shadowCoordProj = shadowCoordProj * 0.5 + 0.5;

  // 2. 深度读取与 unpack
  vec4 packedDepth = texture2D(shadowMap, shadowCoordProj.xy);
  float closestDepth = unpack(packedDepth);

  // 3. 当前片元深度
  float currentDepth = shadowCoordProj.z;

  // 4. 阴影比较 (使用 Bias 防止自遮挡)
  float bias = 0.005; // 根据场景调整，通常 0.005 是个不错的初始值
  float visibility = (currentDepth - bias > closestDepth) ? 0.0 : 1.0;

  return visibility;
}

vec3 blinnPhong() {
  vec3 color = texture2D(uSampler, vTextureCoord).rgb;
  color = pow(color, vec3(2.2));

  vec3 ambient = 0.05 * color;

  vec3 lightDir = normalize(uLightPos);
  vec3 normal = normalize(vNormal);
  float diff = max(dot(lightDir, normal), 0.0);
  vec3 light_atten_coff =
      uLightIntensity / pow(length(uLightPos - vFragPos), 2.0);
  vec3 diffuse = diff * light_atten_coff * color;

  vec3 viewDir = normalize(uCameraPos - vFragPos);
  vec3 halfDir = normalize((lightDir + viewDir));
  float spec = pow(max(dot(halfDir, normal), 0.0), 32.0);
  vec3 specular = uKs * light_atten_coff * spec;

  vec3 radiance = (ambient + diffuse + specular);
  vec3 phongColor = pow(radiance, vec3(1.0 / 2.2));
  return phongColor;
}

void main(void) {

  float visibility;
  visibility = useShadowMap(uShadowMap, vPositionFromLight);
  //visibility = PCF(uShadowMap, vPositionFromLight);
  //visibility = PCSS(uShadowMap, vPositionFromLight);

  vec3 phongColor = blinnPhong();

  gl_FragColor = vec4(phongColor * visibility, 1.0);
}