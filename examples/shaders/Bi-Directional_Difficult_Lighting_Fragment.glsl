precision highp float;
precision highp int;
precision highp sampler2D;

#include <pathtracing_uniforms_and_defines>


uniform sampler2D tTriangleTexture;
uniform sampler2D tAABBTexture;

uniform sampler2D tPaintingTexture;
uniform sampler2D tDarkWoodTexture;
uniform sampler2D tLightWoodTexture;
uniform sampler2D tMarbleTexture;
uniform sampler2D tHammeredMetalNormalMapTexture;

uniform mat4 uDoorObjectInvMatrix;

#define INV_TEXTURE_WIDTH 0.00048828125

#define N_SPHERES 2
#define N_OPENCYLINDERS 3
#define N_QUADS 8
#define N_BOXES 10

vec3 rayOrigin, rayDirection;
// recorded intersection data:
vec3 hitNormal, hitEmission, hitColor;
vec2 hitUV;
float hitRoughness;
float hitObjectID;
int hitTextureID;
int hitType;
bool hitIsModel;

struct Sphere { float radius; vec3 position; vec3 emission; vec3 color; float roughness; int type; bool isModel; };
struct OpenCylinder { float radius; vec3 pos1; vec3 pos2; vec3 emission; vec3 color; float roughness; int type; bool isModel; };
struct Quad { vec3 normal; vec3 v0; vec3 v1; vec3 v2; vec3 v3; vec3 emission; vec3 color; float roughness; int type; bool isModel; };
struct Box { vec3 minCorner; vec3 maxCorner; vec3 emission; vec3 color; float roughness; int type; bool isModel; };

Sphere spheres[N_SPHERES];
OpenCylinder openCylinders[N_OPENCYLINDERS];
Quad quads[N_QUADS];
Box boxes[N_BOXES];


#include <pathtracing_random_functions>

#include <pathtracing_calc_fresnel_reflectance>

#include <pathtracing_sphere_intersect>

#include <pathtracing_opencylinder_intersect>

#include <pathtracing_quad_intersect>

#include <pathtracing_box_intersect>

#include <pathtracing_boundingbox_intersect>

#include <pathtracing_bvhDoubleSidedTriangle_intersect>



vec3 perturbNormal(vec3 nl, vec2 normalScale, vec2 uv)
{
	
        vec3 S = normalize( cross( abs(nl.y) < 0.9 ? vec3(0, 1, 0) : vec3(1, 0, 0), nl ) );
        vec3 T = cross(nl, S);
        vec3 N = normalize( nl );
	// invert S, T when the UV direction is backwards (from mirrored faces),
	// otherwise it will do the normal mapping backwards.
	vec3 NfromST = cross( S, T );
	if( dot( NfromST, N ) < 0.0 )
	{
		S *= -1.0;
		T *= -1.0;
	}
        mat3 tsn = mat3( S, T, N );

	vec3 mapN = texture(tHammeredMetalNormalMapTexture, uv).xyz * 2.0 - 1.0;
	mapN = normalize(mapN);
        mapN.xy *= normalScale;
        
        return normalize( tsn * mapN );
}


vec2 stackLevels[28];

//vec4 boxNodeData0 corresponds to .x = idTriangle,  .y = aabbMin.x, .z = aabbMin.y, .w = aabbMin.z
//vec4 boxNodeData1 corresponds to .x = idRightChild .y = aabbMax.x, .z = aabbMax.y, .w = aabbMax.z

void GetBoxNodeData(const in float i, inout vec4 boxNodeData0, inout vec4 boxNodeData1)
{
	// each bounding box's data is encoded in 2 rgba(or xyzw) texture slots 
	float ix2 = i * 2.0;
	// (ix2 + 0.0) corresponds to .x = idTriangle,  .y = aabbMin.x, .z = aabbMin.y, .w = aabbMin.z 
	// (ix2 + 1.0) corresponds to .x = idRightChild .y = aabbMax.x, .z = aabbMax.y, .w = aabbMax.z 

	ivec2 uv0 = ivec2( mod(ix2 + 0.0, 2048.0), (ix2 + 0.0) * INV_TEXTURE_WIDTH ); // data0
	ivec2 uv1 = ivec2( mod(ix2 + 1.0, 2048.0), (ix2 + 1.0) * INV_TEXTURE_WIDTH ); // data1
	
	boxNodeData0 = texelFetch(tAABBTexture, uv0, 0);
	boxNodeData1 = texelFetch(tAABBTexture, uv1, 0);
}

// this SceneIntersect() function must take rayOrigin and rayDirection as parameters because they are altered for each teapot
//--------------------------------------------------------------------------------------------------------
float SceneIntersect( vec3 rayOrigin, vec3 rayDirection, bool checkModels )
//--------------------------------------------------------------------------------------------------------
{
	vec4 currentBoxNodeData0, nodeAData0, nodeBData0, tmpNodeData0;
	vec4 currentBoxNodeData1, nodeAData1, nodeBData1, tmpNodeData1;
	
	vec4 vd0, vd1, vd2, vd3, vd4, vd5, vd6, vd7;

	vec3 inverseDir = 1.0 / rayDirection;
	vec3 normal;

	vec2 currentStackData, stackDataA, stackDataB, tmpStackData;
	ivec2 uv0, uv1, uv2, uv3, uv4, uv5, uv6, uv7;

	float d;
	float t = INFINITY;
        float stackptr = 0.0;
	float id = 0.0;
	float tu, tv;
	float triangleID = 0.0;
	float triangleU = 0.0;
	float triangleV = 0.0;
	float triangleW = 0.0;

	int modelID = 0;
	int objectCount = 0;
	
	hitObjectID = -INFINITY;
	
	bool skip = false;
	bool triangleLookupNeeded = false;
	bool isRayExiting = false;
	
			
	// ROOM
	for (int i = 0; i < N_QUADS; i++)
        {
		d = QuadIntersect( quads[i].v0, quads[i].v1, quads[i].v2, quads[i].v3, rayOrigin, rayDirection, true );
		if (d < t)
		{
			if (i == 1) // check back wall quad for door portal opening
			{
				vec3 ip = rayOrigin + rayDirection * d;
				if (ip.x > 180.0 && ip.x < 280.0 && ip.y > -100.0 && ip.y < 90.0)
					continue;
			}
			
			t = d;
			hitNormal = normalize( quads[i].normal );
			hitEmission = quads[i].emission;
			hitColor = quads[i].color;
			hitType = quads[i].type;
			hitIsModel = false;
			hitObjectID = float(objectCount);
		}
		objectCount++;
        }
	
	for (int i = 0; i < N_BOXES - 1; i++)
        {
		d = BoxIntersect( boxes[i].minCorner, boxes[i].maxCorner, rayOrigin, rayDirection, normal, isRayExiting );
		if (d < t)
		{
			t = d;
			hitNormal = normalize(normal);
			hitEmission = boxes[i].emission;
			hitColor = boxes[i].color;
			hitType = boxes[i].type;
			hitIsModel = false;
			hitObjectID = float(objectCount);
		}
		objectCount++;
	}
	
	// DOOR (TALL BOX)
	vec3 rObjOrigin, rObjDirection;
	// transform ray into Tall Box's object space
	rObjOrigin = vec3( uDoorObjectInvMatrix * vec4(rayOrigin, 1.0) );
	rObjDirection = vec3( uDoorObjectInvMatrix * vec4(rayDirection, 0.0) );
	d = BoxIntersect( boxes[9].minCorner, boxes[9].maxCorner, rObjOrigin, rObjDirection, normal, isRayExiting );
	
	if (d < t)
	{	
		t = d;
		
		// transfom normal back into world space
		hitNormal = normalize(transpose(mat3(uDoorObjectInvMatrix)) * normal);
		hitEmission = boxes[9].emission;
		hitColor = boxes[9].color;
		hitType = boxes[9].type;
		hitIsModel = false;
		hitObjectID = float(objectCount);
	}
	objectCount++;
	
	for (int i = 0; i < N_OPENCYLINDERS; i++)
        {
		d = OpenCylinderIntersect( openCylinders[i].pos1, openCylinders[i].pos2, openCylinders[i].radius, rayOrigin, rayDirection, normal );
		if (d < t)
		{
			t = d;
			hitNormal = normalize(normal);
			hitEmission = openCylinders[i].emission;
			hitColor = openCylinders[i].color;
			hitType = openCylinders[i].type;
			hitIsModel = false;
			hitObjectID = float(objectCount);
		}
		objectCount++;
        }
	
	for (int i = 0; i < N_SPHERES; i++)
        {
		d = SphereIntersect( spheres[i].radius, spheres[i].position, rObjOrigin, rObjDirection );
		if (d < t)
		{
			t = d;

			normal = normalize((rObjOrigin + rObjDirection * t) - spheres[i].position);
			hitNormal = normalize(transpose(mat3(uDoorObjectInvMatrix)) * normal);
			hitEmission = spheres[i].emission;
			hitColor = spheres[i].color;
			hitType = spheres[i].type;
			hitIsModel = false;
			hitObjectID = float(objectCount);
		}
		objectCount++;
	}

	if (!checkModels)
		return t;

	// teapot 0
	GetBoxNodeData(stackptr, currentBoxNodeData0, currentBoxNodeData1);
	currentStackData = vec2(stackptr, BoundingBoxIntersect(currentBoxNodeData0.yzw, currentBoxNodeData1.yzw, rayOrigin, inverseDir));
	stackLevels[0] = currentStackData;
	skip = (currentStackData.y < t);

	while (true)
        {
		if (!skip) 
                {
                        // decrease pointer by 1 (0.0 is root level, 27.0 is maximum depth)
                        if (--stackptr < 0.0) // went past the root level, terminate loop
                                break;

                        currentStackData = stackLevels[int(stackptr)];
			
			if (currentStackData.y >= t)
				continue;
			
			GetBoxNodeData(currentStackData.x, currentBoxNodeData0, currentBoxNodeData1);
                }
		skip = false; // reset skip
		

		if (currentBoxNodeData0.x < 0.0) // < 0.0 signifies an inner node
		{
			GetBoxNodeData(currentStackData.x + 1.0, nodeAData0, nodeAData1);
			GetBoxNodeData(currentBoxNodeData1.x, nodeBData0, nodeBData1);
			stackDataA = vec2(currentStackData.x + 1.0, BoundingBoxIntersect(nodeAData0.yzw, nodeAData1.yzw, rayOrigin, inverseDir));
			stackDataB = vec2(currentBoxNodeData1.x, BoundingBoxIntersect(nodeBData0.yzw, nodeBData1.yzw, rayOrigin, inverseDir));
			
			// first sort the branch node data so that 'a' is the smallest
			if (stackDataB.y < stackDataA.y)
			{
				tmpStackData = stackDataB;
				stackDataB = stackDataA;
				stackDataA = tmpStackData;

				tmpNodeData0 = nodeBData0;   tmpNodeData1 = nodeBData1;
				nodeBData0   = nodeAData0;   nodeBData1   = nodeAData1;
				nodeAData0   = tmpNodeData0; nodeAData1   = tmpNodeData1;
			} // branch 'b' now has the larger rayT value of 'a' and 'b'

			if (stackDataB.y < t) // see if branch 'b' (the larger rayT) needs to be processed
			{
				currentStackData = stackDataB;
				currentBoxNodeData0 = nodeBData0;
				currentBoxNodeData1 = nodeBData1;
				skip = true; // this will prevent the stackptr from decreasing by 1
			}
			if (stackDataA.y < t) // see if branch 'a' (the smaller rayT) needs to be processed 
			{
				if (skip) // if larger branch 'b' needed to be processed also,
					stackLevels[int(stackptr++)] = stackDataB; // cue larger branch 'b' for future round
							// also, increase pointer by 1
				
				currentStackData = stackDataA;
				currentBoxNodeData0 = nodeAData0; 
				currentBoxNodeData1 = nodeAData1;
				skip = true; // this will prevent the stackptr from decreasing by 1
			}

			continue;
		} // end if (currentBoxNodeData0.x < 0.0) // inner node


		// else this is a leaf

		// each triangle's data is encoded in 8 rgba(or xyzw) texture slots
		id = 8.0 * currentBoxNodeData0.x;

		uv0 = ivec2( mod(id + 0.0, 2048.0), (id + 0.0) * INV_TEXTURE_WIDTH );
		uv1 = ivec2( mod(id + 1.0, 2048.0), (id + 1.0) * INV_TEXTURE_WIDTH );
		uv2 = ivec2( mod(id + 2.0, 2048.0), (id + 2.0) * INV_TEXTURE_WIDTH );
		
		vd0 = texelFetch(tTriangleTexture, uv0, 0);
		vd1 = texelFetch(tTriangleTexture, uv1, 0);
		vd2 = texelFetch(tTriangleTexture, uv2, 0);

		d = BVH_DoubleSidedTriangleIntersect( vec3(vd0.xyz), vec3(vd0.w, vd1.xy), vec3(vd1.zw, vd2.x), rayOrigin, rayDirection, tu, tv );

		if (d < t)
		{
			t = d;
			triangleID = id;
			triangleU = tu;
			triangleV = tv;
			triangleLookupNeeded = true;
			modelID = 0;
		}
	      
        } // end while (true)


	stackptr = 0.0;
	rayOrigin.x -= 70.0;
	// teapot 1
	GetBoxNodeData(stackptr, currentBoxNodeData0, currentBoxNodeData1);
	currentStackData = vec2(stackptr, BoundingBoxIntersect(currentBoxNodeData0.yzw, currentBoxNodeData1.yzw, rayOrigin, inverseDir));
	stackLevels[0] = currentStackData;
	skip = (currentStackData.y < t);

	while (true)
        {
		if (!skip) 
                {
                        // decrease pointer by 1 (0.0 is root level, 27.0 is maximum depth)
                        if (--stackptr < 0.0) // went past the root level, terminate loop
                                break;

                        currentStackData = stackLevels[int(stackptr)];
			
			if (currentStackData.y >= t)
				continue;
			
			GetBoxNodeData(currentStackData.x, currentBoxNodeData0, currentBoxNodeData1);
                }
		skip = false; // reset skip
		

		if (currentBoxNodeData0.x < 0.0) // < 0.0 signifies an inner node
		{
			GetBoxNodeData(currentStackData.x + 1.0, nodeAData0, nodeAData1);
			GetBoxNodeData(currentBoxNodeData1.x, nodeBData0, nodeBData1);
			stackDataA = vec2(currentStackData.x + 1.0, BoundingBoxIntersect(nodeAData0.yzw, nodeAData1.yzw, rayOrigin, inverseDir));
			stackDataB = vec2(currentBoxNodeData1.x, BoundingBoxIntersect(nodeBData0.yzw, nodeBData1.yzw, rayOrigin, inverseDir));
			
			// first sort the branch node data so that 'a' is the smallest
			if (stackDataB.y < stackDataA.y)
			{
				tmpStackData = stackDataB;
				stackDataB = stackDataA;
				stackDataA = tmpStackData;

				tmpNodeData0 = nodeBData0;   tmpNodeData1 = nodeBData1;
				nodeBData0   = nodeAData0;   nodeBData1   = nodeAData1;
				nodeAData0   = tmpNodeData0; nodeAData1   = tmpNodeData1;
			} // branch 'b' now has the larger rayT value of 'a' and 'b'

			if (stackDataB.y < t) // see if branch 'b' (the larger rayT) needs to be processed
			{
				currentStackData = stackDataB;
				currentBoxNodeData0 = nodeBData0;
				currentBoxNodeData1 = nodeBData1;
				skip = true; // this will prevent the stackptr from decreasing by 1
			}
			if (stackDataA.y < t) // see if branch 'a' (the smaller rayT) needs to be processed 
			{
				if (skip) // if larger branch 'b' needed to be processed also,
					stackLevels[int(stackptr++)] = stackDataB; // cue larger branch 'b' for future round
							// also, increase pointer by 1
				
				currentStackData = stackDataA;
				currentBoxNodeData0 = nodeAData0; 
				currentBoxNodeData1 = nodeAData1;
				skip = true; // this will prevent the stackptr from decreasing by 1
			}

			continue;
		} // end if (currentBoxNodeData0.x < 0.0) // inner node


		// else this is a leaf

		// each triangle's data is encoded in 8 rgba(or xyzw) texture slots
		id = 8.0 * currentBoxNodeData0.x;

		uv0 = ivec2( mod(id + 0.0, 2048.0), (id + 0.0) * INV_TEXTURE_WIDTH );
		uv1 = ivec2( mod(id + 1.0, 2048.0), (id + 1.0) * INV_TEXTURE_WIDTH );
		uv2 = ivec2( mod(id + 2.0, 2048.0), (id + 2.0) * INV_TEXTURE_WIDTH );
		
		vd0 = texelFetch(tTriangleTexture, uv0, 0);
		vd1 = texelFetch(tTriangleTexture, uv1, 0);
		vd2 = texelFetch(tTriangleTexture, uv2, 0);

		d = BVH_DoubleSidedTriangleIntersect( vec3(vd0.xyz), vec3(vd0.w, vd1.xy), vec3(vd1.zw, vd2.x), rayOrigin, rayDirection, tu, tv );

		if (d < t)
		{
			t = d;
			triangleID = id;
			triangleU = tu;
			triangleV = tv;
			triangleLookupNeeded = true;
			modelID = 1;
		}
	      
        } // end while (true)


	stackptr = 0.0;
	rayOrigin.x -= 70.0;
	// teapot 2
	GetBoxNodeData(stackptr, currentBoxNodeData0, currentBoxNodeData1);
	currentStackData = vec2(stackptr, BoundingBoxIntersect(currentBoxNodeData0.yzw, currentBoxNodeData1.yzw, rayOrigin, inverseDir));
	stackLevels[0] = currentStackData;
	skip = (currentStackData.y < t);

	while (true)
        {
		if (!skip) 
                {
                        // decrease pointer by 1 (0.0 is root level, 27.0 is maximum depth)
                        if (--stackptr < 0.0) // went past the root level, terminate loop
                                break;

                        currentStackData = stackLevels[int(stackptr)];
			
			if (currentStackData.y >= t)
				continue;
			
			GetBoxNodeData(currentStackData.x, currentBoxNodeData0, currentBoxNodeData1);
                }
		skip = false; // reset skip
		

		if (currentBoxNodeData0.x < 0.0) // < 0.0 signifies an inner node
		{
			GetBoxNodeData(currentStackData.x + 1.0, nodeAData0, nodeAData1);
			GetBoxNodeData(currentBoxNodeData1.x, nodeBData0, nodeBData1);
			stackDataA = vec2(currentStackData.x + 1.0, BoundingBoxIntersect(nodeAData0.yzw, nodeAData1.yzw, rayOrigin, inverseDir));
			stackDataB = vec2(currentBoxNodeData1.x, BoundingBoxIntersect(nodeBData0.yzw, nodeBData1.yzw, rayOrigin, inverseDir));
			
			// first sort the branch node data so that 'a' is the smallest
			if (stackDataB.y < stackDataA.y)
			{
				tmpStackData = stackDataB;
				stackDataB = stackDataA;
				stackDataA = tmpStackData;

				tmpNodeData0 = nodeBData0;   tmpNodeData1 = nodeBData1;
				nodeBData0   = nodeAData0;   nodeBData1   = nodeAData1;
				nodeAData0   = tmpNodeData0; nodeAData1   = tmpNodeData1;
			} // branch 'b' now has the larger rayT value of 'a' and 'b'

			if (stackDataB.y < t) // see if branch 'b' (the larger rayT) needs to be processed
			{
				currentStackData = stackDataB;
				currentBoxNodeData0 = nodeBData0;
				currentBoxNodeData1 = nodeBData1;
				skip = true; // this will prevent the stackptr from decreasing by 1
			}
			if (stackDataA.y < t) // see if branch 'a' (the smaller rayT) needs to be processed 
			{
				if (skip) // if larger branch 'b' needed to be processed also,
					stackLevels[int(stackptr++)] = stackDataB; // cue larger branch 'b' for future round
							// also, increase pointer by 1
				
				currentStackData = stackDataA;
				currentBoxNodeData0 = nodeAData0; 
				currentBoxNodeData1 = nodeAData1;
				skip = true; // this will prevent the stackptr from decreasing by 1
			}

			continue;
		} // end if (currentBoxNodeData0.x < 0.0) // inner node


		// else this is a leaf

		// each triangle's data is encoded in 8 rgba(or xyzw) texture slots
		id = 8.0 * currentBoxNodeData0.x;

		uv0 = ivec2( mod(id + 0.0, 2048.0), (id + 0.0) * INV_TEXTURE_WIDTH );
		uv1 = ivec2( mod(id + 1.0, 2048.0), (id + 1.0) * INV_TEXTURE_WIDTH );
		uv2 = ivec2( mod(id + 2.0, 2048.0), (id + 2.0) * INV_TEXTURE_WIDTH );
		
		vd0 = texelFetch(tTriangleTexture, uv0, 0);
		vd1 = texelFetch(tTriangleTexture, uv1, 0);
		vd2 = texelFetch(tTriangleTexture, uv2, 0);

		d = BVH_DoubleSidedTriangleIntersect( vec3(vd0.xyz), vec3(vd0.w, vd1.xy), vec3(vd1.zw, vd2.x), rayOrigin, rayDirection, tu, tv );

		if (d < t)
		{
			t = d;
			triangleID = id;
			triangleU = tu;
			triangleV = tv;
			triangleLookupNeeded = true;
			modelID = 2;
		}
	      
        } // end while (true)


	if (triangleLookupNeeded)
	{
		uv0 = ivec2( mod(triangleID + 0.0, 2048.0), (triangleID + 0.0) * INV_TEXTURE_WIDTH );
		uv1 = ivec2( mod(triangleID + 1.0, 2048.0), (triangleID + 1.0) * INV_TEXTURE_WIDTH );
		uv2 = ivec2( mod(triangleID + 2.0, 2048.0), (triangleID + 2.0) * INV_TEXTURE_WIDTH );
		uv3 = ivec2( mod(triangleID + 3.0, 2048.0), (triangleID + 3.0) * INV_TEXTURE_WIDTH );
		uv4 = ivec2( mod(triangleID + 4.0, 2048.0), (triangleID + 4.0) * INV_TEXTURE_WIDTH );
		uv5 = ivec2( mod(triangleID + 5.0, 2048.0), (triangleID + 5.0) * INV_TEXTURE_WIDTH );
		uv6 = ivec2( mod(triangleID + 6.0, 2048.0), (triangleID + 6.0) * INV_TEXTURE_WIDTH );
		uv7 = ivec2( mod(triangleID + 7.0, 2048.0), (triangleID + 7.0) * INV_TEXTURE_WIDTH );
		
		vd0 = texelFetch(tTriangleTexture, uv0, 0);
		vd1 = texelFetch(tTriangleTexture, uv1, 0);
		vd2 = texelFetch(tTriangleTexture, uv2, 0);
		vd3 = texelFetch(tTriangleTexture, uv3, 0);
		vd4 = texelFetch(tTriangleTexture, uv4, 0);
		vd5 = texelFetch(tTriangleTexture, uv5, 0);
		vd6 = texelFetch(tTriangleTexture, uv6, 0);
		vd7 = texelFetch(tTriangleTexture, uv7, 0);

	
		// face normal for flat-shaded polygon look
		//hitNormal = normalize( cross(vec3(vd0.w, vd1.xy) - vec3(vd0.xyz), vec3(vd1.zw, vd2.x) - vec3(vd0.xyz)) );
		
		// interpolated normal using triangle intersection's uv's
		triangleW = 1.0 - triangleU - triangleV;
		hitNormal = normalize(triangleW * vec3(vd2.yzw) + triangleU * vec3(vd3.xyz) + triangleV * vec3(vd3.w, vd4.xy));
		hitEmission = vec3(1, 0, 1); // use this if intersec.type will be LIGHT
		//hitColor = vd6.yzw;
		hitUV = triangleW * vec2(vd4.zw) + triangleU * vec2(vd5.xy) + triangleV * vec2(vd5.zw);
		//hitType = int(vd6.x);
		//hitAlbedoTextureID = int(vd7.x);
		hitColor = vec3(0.7);
		hitType = SPEC;
		hitObjectID = float(objectCount);
		objectCount++;
		if (modelID == 1)
		{
			hitColor = vec3(1.2); // makes white teapot a little more white
			hitType = COAT;
			hitObjectID = float(objectCount);
		}
		objectCount++;
		
		if (modelID == 2)
		{
			hitColor = vec3(1);
			hitType = REFR;
			hitObjectID = float(objectCount);
		}
		
		hitIsModel = true;
	}
	
	return t;
	
} // end SceneIntersect( bool checkModels )



//--------------------------------------------------------------------------------------------------------------------------------------------------------------------
vec3 CalculateRadiance( out vec3 objectNormal, out vec3 objectColor, out float objectID, out float pixelSharpness )
//--------------------------------------------------------------------------------------------------------------------------------------------------------------------
{
	vec4 texColor;

	vec3 originalRayOrigin = rayOrigin;
	vec3 originalRayDirection = rayDirection;
	vec3 accumCol = vec3(0);
	vec3 mask = vec3(1);
	vec3 checkCol0 = vec3(0.01);
	vec3 checkCol1 = vec3(1.0);
	vec3 nl, n, x;
	vec3 tdir;
	vec3 dirToLight;

	vec2 sampleUV;
	
	float nc, nt, ratioIoR, Re, Tr;
	float P, RP, TP;
	float t = INFINITY;
	float lightHitDistance = INFINITY;
	float weight;
	float hitObjectID;

	int diffuseCount = 0;
	int previousIntersecType = -1;

	bool coatTypeIntersected = false;
	bool sampleLight = false;
	bool bounceIsSpecular = true;
	bool ableToJoinPaths = false;
	bool checkModels = false;


	// Light path tracing (from Light source) /////////////////////////////////////////////////////////////////////

	vec3 lightHitEmission = quads[0].emission;
	vec3 randPointOnLight;
	randPointOnLight.x = mix(quads[0].v0.x, quads[0].v1.x, rng());
	randPointOnLight.y = mix(quads[0].v0.y, quads[0].v3.y, rng());
	randPointOnLight.z = quads[0].v0.z;
	vec3 lightHitPos = randPointOnLight;
	vec3 lightNormal = normalize(quads[0].normal);
	
	rayDirection = randomCosWeightedDirectionInHemisphere(lightNormal);
	rayOrigin = randPointOnLight + lightNormal * uEPS_intersect; // move light ray out to prevent self-intersection with light
	
	t = SceneIntersect(rayOrigin, rayDirection, checkModels);
		
	if (hitType == DIFF)
	{
		lightHitPos = rayOrigin + rayDirection * t;
		weight = max(0.0, dot(-rayDirection, normalize(hitNormal)));
		lightHitEmission *= hitColor * weight;
	}
	

	// regular path tracing from camera
	rayOrigin = originalRayOrigin;
	rayDirection = originalRayDirection;
	
	checkModels = true;
	hitType = -100;
	hitObjectID = -100.0;


	// Eye path tracing (from Camera) ///////////////////////////////////////////////////////////////////////////
	
	for (int bounces = 0; bounces < 5; bounces++)
	{
	
		t = SceneIntersect(rayOrigin, rayDirection, checkModels);
		
		if (t == INFINITY)
			break;
		
		// useful data 
		n = normalize(hitNormal);
                nl = dot(n, rayDirection) < 0.0 ? normalize(n) : normalize(-n);
		x = rayOrigin + rayDirection * t;

		if (bounces == 0)
		{
			objectNormal = nl;
			objectColor = hitColor;
			objectID = hitObjectID;
		}


		if (hitType == LIGHT)
		{
			if (diffuseCount == 0)
				pixelSharpness = 1.01;
			
			if (bounceIsSpecular || sampleLight)
				accumCol = mask * hitEmission;
			
			break;
		}

		if (hitType == DIFF && sampleLight)
		{
			ableToJoinPaths = abs(t - lightHitDistance) < 0.5;

			pixelSharpness = 0.0;
			
			if (ableToJoinPaths)
			{
				weight = max(0.0, dot(normalize(hitNormal), -rayDirection));
				accumCol = mask * lightHitEmission * weight;
			}

			break;
		}

		// if we reached this point and sampleLight is still true, then we can
		// exit because the light was not found
		if (sampleLight)
			break;
		
		
		
		if ( hitType == DIFF || hitType == LIGHTWOOD ||
		     hitType == DARKWOOD || hitType == PAINTING ) // Ideal DIFFUSE reflection
		{
			if (bounces == 0)
				pixelSharpness = 0.0;
			
			if (hitType == LIGHTWOOD)
			{
				if (abs(nl.x) > 0.5) sampleUV = vec2(x.z, x.y);
				else if (abs(nl.y) > 0.5) sampleUV = vec2(x.x, x.z);
				else sampleUV = vec2(x.x, x.y);
				texColor = texture(tLightWoodTexture, sampleUV * 0.01);
				hitColor *= pow(texColor.rgb, vec3(2.2));
			}
			else if (hitType == DARKWOOD)
			{
				sampleUV = vec2( uDoorObjectInvMatrix * vec4(x, 1.0) );
				texColor = texture(tDarkWoodTexture, sampleUV * vec2(0.01,0.005));
				hitColor *= pow(texColor.rgb, vec3(2.2));
			}
			else if (hitType == PAINTING)
			{
				sampleUV = vec2((55.0 + x.x) / 110.0, (x.y - 20.0) / 44.0);
				texColor = texture(tPaintingTexture, sampleUV);
				hitColor *= pow(texColor.rgb, vec3(2.2));
			}

			if (bounces == 0 || (diffuseCount == 0 && !coatTypeIntersected && previousIntersecType == SPEC))	
				objectColor = hitColor;

			diffuseCount++;
			
			previousIntersecType = DIFF;

			mask *= hitColor;

			bounceIsSpecular = false;

			if (diffuseCount == 1 && rand() < 0.5)
			{
				// choose random Diffuse sample vector
				rayDirection = randomCosWeightedDirectionInHemisphere(nl);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}

			dirToLight = normalize(lightHitPos - x);
			weight = max(0.0, dot(nl, dirToLight));
			mask *= weight;
			
			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;
			lightHitDistance = distance(rayOrigin, lightHitPos);

			sampleLight = true;
			continue;
		}
		
		if (hitType == SPEC)  // Ideal SPECULAR reflection
		{
			previousIntersecType = SPEC;

			mask *= hitColor;
			
			if (hitIsModel)
				nl = perturbNormal(nl, vec2(0.15, 0.15), hitUV * 2.0);

			if (bounces == 0)
				objectNormal = nl;

			 // reflect ray from surface
			rayDirection = randomDirectionInSpecularLobe(reflect(rayDirection, nl), hitRoughness);
			rayOrigin = x + nl * uEPS_intersect;

			continue;
		}
		
		
		if (hitType == REFR)  // Ideal dielectric refraction
		{	
			// if (diffuseCount == 0 && !coatTypeIntersected && !uCameraIsMoving )
			// 	pixelSharpness = 1.01;
			// if (diffuseCount > 0)
			// 	pixelSharpness = 0.0;
			//else
			//	pixelSharpness = -1.0;
			if (bounces == 0)
				pixelSharpness = 1.01;
			else if (diffuseCount > 0)
				pixelSharpness = 0.0;

			nc = 1.0; // IOR of Air
			nt = 1.5; // IOR of common Glass
			Re = calcFresnelReflectance(rayDirection, n, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
                	RP = Re / P;
                	TP = Tr / (1.0 - P);

			if (rand() < P)
			{
				mask *= RP;
				rayDirection = reflect(rayDirection, nl); // reflect ray from surface
				rayOrigin = x + nl * uEPS_intersect;
				
				previousIntersecType = REFR;
				continue;	
			}

			// transmit ray through surface
			
			if (previousIntersecType == DIFF) 
				mask *= 4.0;
		
			previousIntersecType = REFR;
		
			mask *= TP;
			mask *= hitColor;

			tdir = refract(rayDirection, nl, ratioIoR);
			rayDirection = tdir;
			rayOrigin = x - nl * uEPS_intersect;

			continue;
				
		} // end if (hitType == REFR)
		
		if (hitType == COAT || hitType == CHECK)  // Diffuse object underneath with ClearCoat on top
		{	
			coatTypeIntersected = true;

			pixelSharpness = 0.0;

			nc = 1.0; // IOR of Air
			nt = 1.4; // IOR of ClearCoat
			Re = calcFresnelReflectance(rayDirection, nl, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
                	RP = Re / P;
                	TP = Tr / (1.0 - P);

			// choose either specular reflection or diffuse
			if( rand() < P )
			{	
				mask *= RP;
				// reflect ray from surface
				rayDirection = randomDirectionInSpecularLobe(reflect(rayDirection, nl), hitRoughness);
				rayOrigin = x + nl * uEPS_intersect;

				previousIntersecType = COAT;
				continue;	
			}

			if (hitType == CHECK)
			{
				float q = clamp( mod( dot( floor(x.xz * 0.04), vec2(1.0) ), 2.0 ) , 0.0, 1.0 );
				hitColor = checkCol0 * q + checkCol1 * (1.0 - q);	
			}
			
			else if (hitType == COAT)
			{
				// spherical coordinates
				//sampleUV.x = atan(-nl.z, nl.x) * ONE_OVER_TWO_PI + 0.5;
				//sampleUV.y = asin(clamp(nl.y, -1.0, 1.0)) * ONE_OVER_PI + 0.5;
				texColor = texture(tMarbleTexture, hitUV * vec2(-1.0, 1.0));
				hitColor *= pow(texColor.rgb, vec3(2.2));		
			}

			if (bounces == 0)
				objectColor = hitColor;
			
			diffuseCount++;

			previousIntersecType = COAT;

			bounceIsSpecular = false;

			mask *= TP;
			mask *= hitColor;
			
			if (diffuseCount == 1 && rand() < 0.5)
			{
				// choose random Diffuse sample vector
				rayDirection = randomCosWeightedDirectionInHemisphere(nl);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}

			dirToLight = normalize(lightHitPos - x);
			weight = max(0.0, dot(nl, dirToLight));
			mask *= weight;
			
			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;
			lightHitDistance = distance(rayOrigin, lightHitPos);

			sampleLight = true;
			continue;	
				
		} //end if (hitType == COAT)
		
	} // end for (int bounces = 0; bounces < 5; bounces++)
	
	
	return max(vec3(0), accumCol);

}  // end vec3 CalculateRadiance( vec3 originalRayOrigin, vec3 originalRayDirection, out vec3 objectNormal, out vec3 objectColor, out float objectID, out float pixelSharpness )


//-----------------------------------------------------------------------
void SetupScene(void)
//-----------------------------------------------------------------------
{
	vec3 z  = vec3(0);// No color value, Black
	vec3 L2 = vec3(1.0, 0.9, 0.8) * 15.0;// Bright Yellowish light
	vec3 wallColor = vec3(0.5);
	vec3 tableColor = vec3(1.0, 0.7, 0.4) * 0.6;
	vec3 brassColor = vec3(1.0, 0.7, 0.5) * 0.7;
	
	quads[0] = Quad( vec3(0,0,1), vec3( 180,-100,-298.5), vec3( 280,-100,-298.5), vec3( 280,  90,-298.5), vec3( 180,  90,-298.5), L2, z, 0.0, LIGHT, false);// Area Light Quad in doorway
	
	quads[1] = Quad( vec3(0,0,1), vec3(-350,-100,-300), vec3( 350,-100,-300), vec3( 350, 150,-300), vec3(-350, 150,-300),  z, wallColor, 0.0,   DIFF, false);// Back Wall (in front of camera, visible at startup)
	quads[2] = Quad( vec3(0,0,-1), vec3( 350,-100, 200), vec3(-350,-100, 200), vec3(-350, 150, 200), vec3( 350, 150, 200),  z, wallColor, 0.0,   DIFF, false);// Front Wall (behind camera, not visible at startup)
	quads[3] = Quad( vec3(1,0,0), vec3(-350,-100, 200), vec3(-350,-100,-300), vec3(-350, 150,-300), vec3(-350, 150, 200),  z, wallColor, 0.0,   DIFF, false);// Left Wall
	quads[4] = Quad( vec3(-1,0,0), vec3( 350,-100,-300), vec3( 350,-100, 200), vec3( 350, 150, 200), vec3( 350, 150,-300),  z, wallColor, 0.0,   DIFF, false);// Right Wall
	quads[5] = Quad( vec3(0,-1,0), vec3(-350, 150,-300), vec3( 350, 150,-300), vec3( 350, 150, 200), vec3(-350, 150, 200),  z, vec3(1), 0.0,   DIFF, false);// Ceiling
	quads[6] = Quad( vec3(0,1,0), vec3(-350,-100,-300), vec3(-350,-100, 200), vec3( 350,-100, 200), vec3( 350,-100,-300),  z, vec3(1), 0.0,  CHECK, false);// Floor
	
	quads[7] = Quad( vec3(0,0,1), vec3(-55, 20,-295), vec3( 55, 20,-295), vec3( 55, 65,-295), vec3(-55, 65,-295), z, vec3(1.0), 0.0, PAINTING, false);// Wall Painting
	
	boxes[0] = Box( vec3(-100,-60,-230), vec3(100,-57,-130), z, vec3(1.0), 0.0, LIGHTWOOD, false);// Table Top
	boxes[1] = Box( vec3(-90,-100,-150), vec3(-84,-60,-144), z, vec3(0.8, 0.85, 0.9),  0.1, SPEC, false);// Table leg left front
	boxes[2] = Box( vec3(-90,-100,-220), vec3(-84,-60,-214), z, vec3(0.8, 0.85, 0.9),  0.1, SPEC, false);// Table leg left rear
	boxes[3] = Box( vec3( 84,-100,-150), vec3( 90,-60,-144), z, vec3(0.8, 0.85, 0.9),  0.1, SPEC, false);// Table leg right front
	boxes[4] = Box( vec3( 84,-100,-220), vec3( 90,-60,-214), z, vec3(0.8, 0.85, 0.9),  0.1, SPEC, false);// Table leg right rear
	
	boxes[5] = Box( vec3(-60, 15, -299), vec3( 60, 70, -296), z, vec3(0.01, 0, 0), 0.3, SPEC, false);// Painting Frame
	
	boxes[6] = Box( vec3( 172,-100,-302), vec3( 180,  98,-299), z, vec3(0.001), 0.3, SPEC, false);// Door Frame left
	boxes[7] = Box( vec3( 280,-100,-302), vec3( 288,  98,-299), z, vec3(0.001), 0.3, SPEC, false);// Door Frame right
	boxes[8] = Box( vec3( 172,  90,-302), vec3( 288,  98,-299), z, vec3(0.001), 0.3, SPEC, false);// Door Frame top
	boxes[9] = Box( vec3(   0, -94,  -3), vec3( 101,  95,   3), z, vec3(0.7), 0.0, DARKWOOD, false);// Door
	
	openCylinders[0] = OpenCylinder( 1.5, vec3( 179,  64,-297), vec3( 179,  80,-297), z, brassColor, 0.2, SPEC, false);// Door Hinge upper
	openCylinders[1] = OpenCylinder( 1.5, vec3( 179,  -8,-297), vec3( 179,   8,-297), z, brassColor, 0.2, SPEC, false);// Door Hinge middle
	openCylinders[2] = OpenCylinder( 1.5, vec3( 179, -80,-297), vec3( 179, -64,-297), z, brassColor, 0.2, SPEC, false);// Door Hinge lower
	
	spheres[0] = Sphere( 4.0, vec3( 88, -10,  7.8), z, brassColor, 0.0, SPEC, false);// Door knob front
	spheres[1] = Sphere( 4.0, vec3( 88, -10, -7), z, brassColor, 0.0, SPEC, false);// Door knob back
}


#include <pathtracing_main>
