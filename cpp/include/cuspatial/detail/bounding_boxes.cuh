/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cuspatial/detail/utility/validation.hpp>
#include <cuspatial/geometry/vec_2d.hpp>
#include <cuspatial/iterator_factory.cuh>
#include <cuspatial/traits.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/iterator/discard_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/reduce.h>
#include <type_traits>

namespace cuspatial {

namespace detail {

template <typename T>
struct point_bounding_box {
  vec_2d<T> box_offset{};

  CUSPATIAL_HOST_DEVICE point_bounding_box(T expansion_radius = T{0})
    : box_offset{expansion_radius, expansion_radius}
  {
  }

  inline CUSPATIAL_HOST_DEVICE box<T> operator()(vec_2d<T> const& point)
  {
    return box<T>{point - box_offset, point + box_offset};
  }
};

template <typename T>
struct box_minmax {
  inline CUSPATIAL_HOST_DEVICE box<T> operator()(box<T> const& a, box<T> const& b)
  {
    return {box_min(box_min(a.v1, a.v2), b.v1), box_max(box_max(a.v1, a.v2), b.v2)};
  }
};

}  // namespace detail

template <typename IdInputIt, typename PointInputIt, typename BoundingBoxOutputIt, typename T>
BoundingBoxOutputIt point_bounding_boxes(IdInputIt ids_first,
                                         IdInputIt ids_last,
                                         PointInputIt points_first,
                                         BoundingBoxOutputIt bounding_boxes_first,
                                         T expansion_radius,
                                         rmm::cuda_stream_view stream)
{
  static_assert(std::is_floating_point_v<T>, "expansion_radius must be a floating-point type");

  using CoordinateType = iterator_vec_base_type<PointInputIt>;
  using IdType         = iterator_value_type<IdInputIt>;

  auto point_bboxes_first = thrust::make_transform_iterator(
    points_first,
    detail::point_bounding_box<CoordinateType>{static_cast<CoordinateType>(expansion_radius)});

  [[maybe_unused]] auto [_, bounding_boxes_last] =
    thrust::reduce_by_key(rmm::exec_policy(stream),
                          ids_first,
                          ids_last,
                          point_bboxes_first,
                          thrust::make_discard_iterator(),
                          bounding_boxes_first,
                          thrust::equal_to<IdType>(),
                          detail::box_minmax<CoordinateType>{});

  return bounding_boxes_last;
}

template <class LinestringOffsetIterator,
          class VertexIterator,
          class BoundingBoxIterator,
          class T,
          class IndexT>
BoundingBoxIterator linestring_bounding_boxes(LinestringOffsetIterator linestring_offsets_first,
                                              LinestringOffsetIterator linestring_offsets_last,
                                              VertexIterator linestring_vertices_first,
                                              VertexIterator linestring_vertices_last,
                                              BoundingBoxIterator bounding_boxes_first,
                                              T expansion_radius,
                                              rmm::cuda_stream_view stream)
{
  static_assert(is_same<T, iterator_vec_base_type<VertexIterator>>(),
                "expansion_radius type must match vertex floating-point type");

  static_assert(is_floating_point<T>(), "Only floating point polygon vertices supported");

  static_assert(is_vec_2d<iterator_value_type<VertexIterator>>,
                "Input vertices must be cuspatial::vec_2d");

  static_assert(cuspatial::is_integral<iterator_value_type<LinestringOffsetIterator>>(),
                "Offset iterators must have integral value type.");

  // GeoArrow: Number of linestrings is number of offsets minus one.
  auto const num_linestrings = std::distance(linestring_offsets_first, linestring_offsets_last) - 1;
  auto const num_vertices    = std::distance(linestring_vertices_first, linestring_vertices_last);

  if (num_linestrings == 0 || num_vertices == 0) { return bounding_boxes_first; }

  auto vertex_ids_iter =
    make_geometry_id_iterator<IndexT>(linestring_offsets_first, linestring_offsets_last);

  return point_bounding_boxes(vertex_ids_iter,
                              vertex_ids_iter + num_vertices,
                              linestring_vertices_first,
                              bounding_boxes_first,
                              expansion_radius,
                              stream);
}

template <class PolygonOffsetIterator,
          class RingOffsetIterator,
          class VertexIterator,
          class BoundingBoxIterator,
          class T,
          class IndexT>
BoundingBoxIterator polygon_bounding_boxes(PolygonOffsetIterator polygon_offsets_first,
                                           PolygonOffsetIterator polygon_offsets_last,
                                           RingOffsetIterator polygon_ring_offsets_first,
                                           RingOffsetIterator polygon_ring_offsets_last,
                                           VertexIterator polygon_vertices_first,
                                           VertexIterator polygon_vertices_last,
                                           BoundingBoxIterator bounding_boxes_first,
                                           T expansion_radius,
                                           rmm::cuda_stream_view stream)
{
  static_assert(is_same<T, iterator_vec_base_type<VertexIterator>>(),
                "expansion_radius type must match vertex floating-point type");

  static_assert(is_floating_point<T>(), "Only floating point polygon vertices supported");

  static_assert(is_vec_2d<iterator_value_type<VertexIterator>>,
                "Input vertices must be cuspatial::vec_2d");

  static_assert(cuspatial::is_integral<iterator_value_type<PolygonOffsetIterator>,
                                       iterator_value_type<RingOffsetIterator>>(),
                "OffsetIterators must have integral value type.");

  auto const num_polys = std::distance(polygon_offsets_first, polygon_offsets_last) - 1;
  auto const num_rings = std::distance(polygon_ring_offsets_first, polygon_ring_offsets_last) - 1;
  auto const num_vertices = std::distance(polygon_vertices_first, polygon_vertices_last);

  if (num_polys > 0) {
    CUSPATIAL_EXPECTS_VALID_POLYGON_SIZES(
      num_vertices,
      std::distance(polygon_offsets_first, polygon_offsets_last),
      std::distance(polygon_ring_offsets_first, polygon_ring_offsets_last));

    if (num_polys == 0 || num_rings == 0 || num_vertices == 0) { return bounding_boxes_first; }

    auto vertex_ids_iter = make_geometry_id_iterator<IndexT>(
      polygon_offsets_first, polygon_offsets_last, polygon_ring_offsets_first);

    return point_bounding_boxes(vertex_ids_iter,
                                vertex_ids_iter + num_vertices,
                                polygon_vertices_first,
                                bounding_boxes_first,
                                expansion_radius,
                                stream);
  }
  return bounding_boxes_first;
}

}  // namespace cuspatial
